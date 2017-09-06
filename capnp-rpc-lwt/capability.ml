open Lwt.Infix
open Capnp_core

module Log = Capnp_rpc.Debug.Log
module StructStorage = Capnp.BytesMessage.StructStorage

type 'a t = Core_types.cap
type 'a capability_t = 'a t
type ('t, 'a, 'b) method_t = ('t, 'a, 'b) Capnp.RPC.MethodID.t

module Request = Request

let inc_ref = Core_types.inc_ref
let dec_ref = Core_types.dec_ref
let pp f x = x#pp f

let broken = Core_types.broken_cap
let when_broken = Core_types.when_broken
let problem x = x#problem

let wait_until_settled x =
  let result, set_result = Lwt.wait () in
  let rec aux x =
    if x#blocker = None then (
      Lwt.wakeup set_result ()
    ) else (
      x#when_more_resolved (fun x ->
          Core_types.dec_ref x;
          aux x
        )
    )
  in
  aux x;
  result

let equal a b =
  match a#blocker, b#blocker with
  | None, None ->
    let a = a#shortest in
    let b = b#shortest in
    begin match a#problem, b#problem with
    | None, None -> Ok (a = b)
    | Some a, Some b -> Ok (a = b)
    | _ -> Ok false
    end
  | _ -> Error `Unsettled

let call (target : 't capability_t) (m : ('t, 'a, 'b) method_t) (req : 'a Request.t) =
  Log.info (fun f -> f "Calling %a" Capnp.RPC.MethodID.pp m);
  let msg = Request.finish m req in
  let results, resolver = Local_struct_promise.make () in
  target#call resolver msg;
  results

let call_and_wait cap (m : ('t, 'a, 'b StructStorage.reader_t) method_t) req =
  let p, r = Lwt.task () in
  let result = call cap m req in
  let finish = lazy (Core_types.dec_ref result) in
  Lwt.on_cancel p (fun () -> Lazy.force finish);
  result#when_resolved (function
      | Error _ as e -> Lwt.wakeup r e
      | Ok resp ->
        Lazy.force finish;
        let payload = Msg.Response.readable resp in
        let release_response_caps () = Core_types.Response_payload.release resp in
        let contents = Schema.Reader.Payload.content_get payload |> Schema.Reader.of_pointer in
        Lwt.wakeup r @@ Ok (contents, release_response_caps)
    );
  p

let call_for_value cap m req =
  call_and_wait cap m req >|= function
  | Error _ as response -> response
  | Ok (response, release_response_caps) ->
    release_response_caps ();
    Ok response

let call_for_value_exn cap m req =
  call_for_value cap m req >>= function
  | Ok x -> Lwt.return x
  | Error e ->
    let msg = Fmt.strf "Error calling %t(%a): %a"
        cap#pp
        Capnp.RPC.MethodID.pp m
        Capnp_rpc.Error.pp e in
    Lwt.fail (Failure msg)

let call_for_unit cap m req =
  call_for_value cap m req >|= function
  | Ok _ -> Ok ()
  | Error _ as e -> e

let call_for_unit_exn cap m req = call_for_value_exn cap m req >|= ignore

let call_for_caps cap m req fn =
  let q = call cap m req in
  match fn q with
  | r -> Core_types.dec_ref q; r
  | exception ex -> Core_types.dec_ref q; raise ex

type 'a resolver = Cap_proxy.resolver_cap

let promise () =
  let cap = Cap_proxy.local_promise () in
  (cap :> Core_types.cap), (cap :> 'a resolver)

let resolve_ok r x = r#resolve x

let resolve_exn r ex = r#resolve (Core_types.broken_cap ex)
