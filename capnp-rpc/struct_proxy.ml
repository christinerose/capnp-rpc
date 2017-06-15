open Asetmap

module Log = Debug.Log

module Make (C : S.CORE_TYPES) = struct
  open C

  class type struct_ref_internal = object
    inherit struct_resolver

    method pipeline : Path.t -> Request.t -> cap RO_array.t -> struct_ref
    method inc_ref : Path.t -> unit
    method dec_ref : Path.t -> unit
  end

  module Field_map = Map.Make(Path)

  class type field_cap = object
    inherit cap
    method resolve : cap -> unit
  end

  type field = {
    cap : field_cap;
    mutable ref_count : int;
  }

  type 'a unresolved = {
    mutable target : 'a;
    mutable fields : field Field_map.t;
    when_resolved : (struct_ref -> unit) Queue.t;
    mutable cancelling : bool;    (* User called [finish], but results may still arrive. *)
  }

  type 'a state =
    | Unresolved of 'a unresolved
    | Forwarding of struct_ref
    | Finished

  let pp_fields = Field_map.dump (fun f (k, v) -> Fmt.pf f "%a:rc=%d" Path.pp k v.ref_count)

  let pp_state ~pp_promise f = function
    | Unresolved {target; cancelling = true; _} -> Fmt.pf f "%a (cancelling)" pp_promise target
    | Unresolved {target; _} -> Fmt.pf f "%a" pp_promise target
    | Forwarding p -> p#pp f
    | Finished -> Fmt.pf f "(finished)"

  let dispatch state ~cancelling_ok ~unresolved ~forwarding =
    match state with
    | Finished -> failwith "Already finished"
    | Unresolved { cancelling = true; _ } when not cancelling_ok -> failwith "Already finished"
    | Unresolved x -> unresolved x
    | Forwarding x -> forwarding x

  type field_state =
    | PromiseField of struct_ref_internal * C.Path.t
    | ForwardingField of cap

  let field path (p:#struct_ref_internal) =
    object (self : #field_cap)
      val mutable state = PromiseField (p, path)

      method call msg caps =
        match state with
        | PromiseField (p, path) -> p#pipeline path msg caps
        | ForwardingField c -> c#call msg caps

      method pp f =
        match state with
        | PromiseField (p, path) -> Fmt.pf f "field:%a -> %t" Path.pp path p#pp
        | ForwardingField c -> Fmt.pf f "field -> %t" c#pp

      method inc_ref =
        match state with
        | PromiseField (p, path) -> p#inc_ref path
        | ForwardingField c -> c#inc_ref

      method dec_ref =
        Log.info (fun f -> f "dec_ref %t" self#pp);
        match state with
        | PromiseField (p, path) -> p#dec_ref path
        | ForwardingField c -> c#dec_ref

      method resolve cap =
        Log.info (fun f -> f "resolve field");
        match state with
        | ForwardingField _ -> failwith "Field already resolved!"
        | PromiseField _ -> state <- ForwardingField cap

      method shortest =
        match state with
        | ForwardingField c -> c#shortest
        | PromiseField _ -> (self :> cap)
    end

  class virtual ['promise] t init = object (self : #struct_resolver)
    val mutable state =
      Unresolved {
        target = init;
        fields = Field_map.empty;
        when_resolved = Queue.create ();
        cancelling = false
      }

    method private virtual do_pipeline : 'promise -> Path.t -> Request.t -> cap RO_array.t -> struct_ref

    method private virtual on_resolve : 'promise -> struct_ref -> unit
    (* We have just started forwarding. Send any queued data onwards. *)

    method private virtual do_finish : 'promise -> unit

    method pipeline path msg caps =
      dispatch state
        ~cancelling_ok:true
        ~unresolved:(fun x -> self#do_pipeline x.target path msg caps)
        ~forwarding:(fun x -> (x#cap path)#call msg caps)

    method response =
      match state with
      | Unresolved {cancelling = true; _} | Finished -> Some (Error `Cancelled)
      | Unresolved _ -> None
      | Forwarding x -> x#response

    method cap path =
      dispatch state
        ~cancelling_ok:false
        ~unresolved:(fun u ->
            let field =
              match Field_map.find path u.fields with
              | Some f -> f
              | None ->
                let cap = field path (self :> struct_ref_internal) in
                let field = {cap; ref_count = 1} in
                u.fields <- Field_map.add path field u.fields; (* Map takes initial ref *)
                field
            in
            field.ref_count <- field.ref_count + 1;  (* Ref for user *)
            (field.cap :> cap)
          )
        ~forwarding:(fun x -> x#cap path)

    method pp f =
      let pp_promise f _ = Fmt.string f "(unresolved)" in
      Fmt.pf f "proxy -> %a" (pp_state ~pp_promise) state

    method connect x =
      Log.info (fun f -> f "@[Updating: %t@\n\
                            @      to: -> %t" self#pp x#pp);
      dispatch state
        ~cancelling_ok:true
        ~unresolved:(fun u ->
            state <- Forwarding x;
            u.fields |> Field_map.iter (fun path f ->
                if f.ref_count > 1 then (
                  let c = x#cap path in   (* Increases ref by one *)
                  f.cap#resolve c;
                  (* We drop our ref, and [f.cap] took one above. The rest we pass on. *)
                  for _ = 3 to f.ref_count do c#inc_ref done
                )
              );
            self#on_resolve u.target x;
            Queue.iter (fun fn -> fn x) u.when_resolved;
            if u.cancelling then self#finish
          )
        ~forwarding:(fun t ->
            failwith (Fmt.strf "Already forwarding (to %t)!" t#pp)
          )

    method resolve result = self#connect (resolved result)

    method finish =
      dispatch state
        ~cancelling_ok:false
        ~unresolved:(fun u ->
            u.cancelling <- true;
            if Field_map.is_empty u.fields then
              self#do_finish u.target;
            (* else disable locally but don't send a cancel because we still
               want the caps. *)
          )
        ~forwarding:(fun x ->
            state <- Finished;
            x#finish
          )

    method when_resolved fn =
      dispatch state
        ~cancelling_ok:false
        ~unresolved:(fun u -> Queue.add (fun p -> p#when_resolved fn) u.when_resolved)
        ~forwarding:(fun x -> x#when_resolved fn)

    method inc_ref path =
      dispatch state
        ~cancelling_ok:true
        ~unresolved:(fun u ->
            (* When we resolve, we'll be holding references to all the caps in the resolution, so
               so they must still be alive by the time we pass on any extra inc or dec refs. *)
            let f = Field_map.get path u.fields in
            assert (f.ref_count > 1);   (* rc can't be one because that's our reference *)
            f.ref_count <- f.ref_count + 1
          )
        ~forwarding:(fun x -> (x#cap path)#inc_ref)

    method dec_ref path =
      dispatch state
        ~cancelling_ok:true
        ~unresolved:(fun u ->
            let f = Field_map.get path u.fields in
            assert (f.ref_count > 1);   (* rc can't be one because that's our reference *)
            f.ref_count <- f.ref_count - 1
          )
        ~forwarding:(fun x -> (x#cap path)#dec_ref)

    method private update_target target =
      dispatch state
        ~cancelling_ok:false
        ~unresolved:(fun u -> u.target <- target)
        ~forwarding:(fun _ -> failwith "Already forwarding!")
  end
end