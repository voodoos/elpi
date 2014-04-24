(* elpi: embedded lambda prolog interpreter                                  *)
(* copyright: 2014 - Enrico Tassi <enrico.tassi@inria.fr>                    *)
(* license: GNU Lesser General Public License Version 2.1                    *)
(* ------------------------------------------------------------------------- *)

open Lpdata
open LP
open Subst
open Red

(* Based on " An Implementation of the Language Lambda Prolog Organized around
   Higher-Order Pattern Unification", Xiaochu Qi (pages 51 and 52)
   or "Practical Higher-Order Pattern Unification With On-the-Fly Raising",
   Gopalan Nadathur and Natalie Linnell. LNCS 3668 *)

exception UnifFail of string lazy_t

let _ = Trace.pr_exn
  (function UnifFail s -> "unif: "^Lazy.force s | _ -> raise Trace.Unknown)

let fail s = raise (UnifFail (lazy s))
let lfail l = raise (UnifFail l)

let print_unif_prob s rel a b fmt =
  Format.fprintf fmt "@[%a@ %s %a@]%!"
    (prf_data []) (apply_subst s a) rel (prf_data []) (apply_subst s b)

let rec rigid x = match x with
  | Uv _ -> false
  | App xs -> rigid (look (IA.get 0 xs))
  | _ -> true

let eta n t = TRACE "eta" (fun fmt -> prf_data [] fmt t)
 let t =
   fixApp (IA.init (n+1) (fun i -> if i = 0 then (lift n t) else mkDB (n+1-i))) in
 SPY "etaed" (prf_data []) t;
 t

let inter xs ys = IA.filter (fun x -> not(IA.for_all (equal x) ys)) xs

(* construction of bindings: ↓ is ^- and ⇑ is ^= *)
let cst_lower xs lvl =
  IA.filter (fun x -> match look x with Con(_,l) -> l <= lvl | _ -> false) xs
let (^=) = cst_lower

let rec position_of i stop v = (); fun x ->
  if i = stop then fail "cannot occur"
  else if equal x (IA.get i v) then mkDB (stop - i)
  else position_of (i+1) stop v x
let (^-) what where = IA.map (position_of 0 (IA.len where) where) what
let (^--) x v = position_of 0 (IA.len v) v x

let mk_al nbinders args =
  (* builds: map (lift nbinders) args @ [DB nbinders ... DB 1] *)
  let nargs = IA.len args in
  IA.init (nbinders + nargs)
    (fun i ->
      if i < nargs then Red.lift nbinders (IA.get i args)
      else mkDB (nargs + nbinders - i))

(* pattern unification fragment *)
let higher lvl x = match look x with (DB l | Con(_,l)) -> l > lvl | _ -> false
let rec not_in v len i x =
  if i+1 = len then true
  else not(equal x (IA.get (i+1) v)) && not_in v len (i+1) x
let isPU xs =
  match look (IA.get 0 xs) with
  | Uv (_,lvl) ->
      IA.for_alli (fun i x -> i = 0 || higher lvl x) xs &&
      IA.for_alli (fun i x -> i = 0 || not_in xs (IA.len xs) i x) xs
  | _ -> false

let rec bind x id depth lvl args t s =
  let t, s = whd s t in
  TRACE "bind" (print_unif_prob s (":= "^string_of_int depth^"↓") x t)
  match look t with
  | Bin(m,t) -> let t, s = bind x id (depth+m) lvl args t s in mkBin m t, s
  | Ext _ -> t, s
  | Con (_,l) when l <= lvl -> t, s
  | Con _ -> t ^-- mk_al depth args, s (* XXX optimize *)
  (* the following 2 cases are: t ^-- mk_al depth args, s *) (* XXX CHECK *)
  | DB m when m <= depth -> t, s
  | DB m -> lift depth (mkDB (m-depth) ^-- args), s
  | Seq(xs,tl) ->
      let xs, s = IA.fold_map (bind x id depth lvl args) xs s in
      let tl, s = bind x id depth lvl args tl s in
      mkSeq xs tl, s
  | Nil -> t, s
  | App bs as t when rigid t ->
      let ss, s = IA.fold_map (bind x id depth lvl args) bs s in
      mkApp ss, s
  | (App _ | Uv _) as tmp -> (* pruning *)
      let bs = match tmp with
        | App bs -> bs | Uv _ -> IA.of_array [|t|] | _ -> assert false in
      match look (IA.get 0 bs) with
      | (Bin _ | Con _ | DB _ | Ext _ | App _ | Seq _ | Nil) -> assert false
      | Uv(j,l) when j <> id && l > lvl && isPU bs ->
          let bs = IA.tl bs in
          let nbs = IA.len bs in
          let h, s = fresh_uv lvl s in
          let al = mk_al depth args in
          let cs = al ^= l in (* constants X = id,lvl can copy *)
          let ws = cs ^- al in
          let zs = inter al bs in (* XXX paper excludes #l-1, why? *)
          let vs = zs ^- al in
          let us = zs ^- bs in
          let nws, nvs, ncs, nus = IA.len ws, IA.len vs, IA.len cs, IA.len us in
          let vj = mkBin nbs (mkAppv h (IA.append cs us) 0 (ncs + nus)) in
          let s = set_sub j vj s in
          let t = mkAppv h (IA.append ws vs) 0 (nws+nvs) in
          SPY "vj" (prf_data []) vj; SPY "t" (prf_data[]) t;
          t, s
      | Uv(j,l) when j <> id && isPU bs ->
          let bs = IA.tl bs in
          let nbs = IA.len bs in
          let h, s = fresh_uv (*lv*)l s in
          let cs = bs ^= lvl in (* constants X = id,lvl can copy *)
          let ws = cs ^- bs in
          let al = mk_al depth args in
          let zs = inter al bs in (* XXX paper excludes #l-1, why? *)
          let vs = zs ^- bs in
          let us = zs ^- al in
          let nws, nvs, ncs, nus = IA.len ws, IA.len vs, IA.len cs, IA.len us in
          let vj = mkBin nbs (mkAppv h (IA.append ws vs) 0 (nws + nvs)) in
          let s = set_sub j vj s in
          let t = mkAppv h (IA.append cs us) 0 (ncs+nus) in
          SPY "vj" (prf_data []) vj; SPY "t" (prf_data[]) t;
          t, s
      | Uv _ -> fail "ho-ho"

let mksubst x id lvl t args s =
  let nargs = IA.len args in
(*
  match look t with
  | Bin(k,Uv(id1,_)) when id1 = id -> assert false (* TODO *)
  | Bin(k,App xs) when equal (IA.get 0 xs) (Uv (id,lvl)) && isPU xs ->
      assert false (* TODO *)
  | _ ->
*)
     let t, s = bind x id 0 lvl args t s in
     set_sub id (mkBin nargs t) s

let rec splay xs tl s =
  let tl, s = whd s tl in
  match look tl with
  | Uv _ | Nil -> xs, tl, s
  | Seq(ys,t) -> splay (IA.append xs ys) t s
  | _ -> assert false

let rec unify a b s = TRACE "unify" (print_unif_prob s "=" a b)
  let a, s =  whd s a in
  let b, s =  whd s b in
  match look a, look b with
  | Con _, Con _ | Ext _, Ext _ | DB _, DB _ | Nil, Nil ->
      if equal a b then s else fail "rigid"
  | Bin(nx,x), Bin(ny,y) when nx = ny -> unify x y s
  | Bin(nx,x), Bin(ny,y) when nx < ny -> unify (eta (ny-nx) x) y s
  | Bin(nx,x), Bin(ny,y) when nx > ny -> unify x (eta (nx-ny) y) s
  | ((Bin(nx,x), y) | (y, Bin(nx,x))) when rigid y -> unify x (eta nx (kool y)) s
  | Uv(i,_), Uv(j,_) when i = j -> s
  | x, y -> if rigid x && rigid y then unify_fo x y s else unify_ho x y s
and unify_fo x y s =
  match x, y with
  | App xs, App ys when IA.len xs = IA.len ys -> IA.fold2 unify xs ys s
  | Seq(xs,tl), Seq(ys,sl) ->
      let xs, tl, s = splay xs tl s in
      let ys, sl, s = splay ys sl s in
      let nxs, nys = IA.len xs, IA.len ys in
      if nxs = nys then unify tl sl (IA.fold2 unify xs ys s)
      else if nxs < nys && not (rigid (look tl)) then
        let yshd, ystl = IA.sub 0 nxs ys, IA.sub nxs (nys - nxs) ys in
        unify tl (mkSeq ystl mkNil) (IA.fold2 unify xs yshd s)
      else if nxs > nys && not (rigid (look sl)) then
        let xshd, xstl = IA.sub 0 nys xs, IA.sub nys (nxs - nys) xs in
        unify sl (mkSeq xstl mkNil) (IA.fold2 unify ys xshd s)
      else fail "listalign"
  | _ -> fail "founif"
and unify_ho x y s =
  match x, y with
  | (((Uv (id,lvl) as x), y) | (y, (Uv (id,lvl) as x))) ->
      mksubst (kool x) id lvl (kool y) (IA.init 0 (fun _ -> kool y)) s
  | (((App xs as x), y) | (y, (App xs as x))) when isPU xs -> begin
      match look (IA.get 0 xs) with
      | Uv (id,lvl) -> mksubst (kool x) id lvl (kool y) (IA.tl xs) s
      | _ -> assert false
    end
  | _ -> fail "not a pattern unif"

(* ******************************** Main loop ******************************* *)

exception NoClause
type objective =
  [ `Atom of data | `Unify of data * data | `Custom of string * data ]
type goal = int * objective * annot_clause list

(* Important: when we move under a pi we put a constant in place of the
 * bound variable. This way hypothetical clauses do not need to be lifted
 * when we move under other pi binders *)
let mkhv_aux =
  let i = ref 0 in
  let small_digit = function
    | 0 -> "₀" | 1 -> "₁" | 2 -> "₂" | 3 -> "₃" | 4 -> "₄" | 5 -> "₅"
    | 6 -> "₆" | 7 -> "₇" | 8 -> "₈" | 9 -> "₉" | _ -> assert false in
  let rec digits_of n = n mod 10 :: if n > 10 then digits_of (n / 10) else [] in
  fun depth ->
    incr i;
    mkCon ("𝓱"^
      String.concat "" (List.map small_digit (List.rev (digits_of !i)))) depth
let rec mkhv n d =
  if n = 0 then []
  else mkhv_aux d :: mkhv (n-1) d

let rec fresh_uv n d s =
  if n = 0 then [], s
  else 
    let m, s = Subst.fresh_uv d s in
    let tl, s = fresh_uv (n-1) d s in
    m :: tl, s

let contextualize depth t hv = Red.beta_under depth t (List.rev hv)

let contextualize_premise depth subst premise : goal list * subst =
  let rec aux cdepth depth s hv eh = function
  | Atom t ->
      [cdepth,`Atom(contextualize 0 t hv), List.map (fun c -> cdepth, c) eh], s
  | AtomBI (BIUnif(x,y)) ->
      [cdepth, `Unify(contextualize 0 x hv,contextualize 0 y hv),
       List.map (fun c -> cdepth, c) eh], s
  | AtomBI (BICustom(n,x)) ->
      [cdepth, `Custom(n,contextualize 0 x hv),
       List.map (fun c -> cdepth, c) eh], s
  | Impl(p,h) ->
      let p, _ = fold_map_premise 0 (fun i t _ -> contextualize i t hv,()) p () in
      aux cdepth depth s hv (p :: eh) h
  | Pi(n,h) -> aux (cdepth+n) depth s (mkhv n (depth+1) @ hv) eh h
  | Sigma(n,h) ->
      let ms, s = fresh_uv n cdepth s in
      aux cdepth depth s (ms @ hv) eh h
  | Conj l ->
      let ll, s = List.fold_right (fun p (acc,s) ->
        let l, s = aux cdepth depth s hv eh p in
        l::acc, s) l ([],s) in
      List.flatten ll, s
  in
    aux depth depth subst [] [] premise

let contextualize_hyp depth subst premise =
  match contextualize_premise depth subst premise with
  | [_,`Atom hd,hyps], s -> hd, hyps, s
  | _ -> assert false

let contextualize_goal depth subst goal =
  contextualize_premise depth subst goal

let rec select (goal : data) depth s (prog : program) :
  subst * goal list * program
=
  match prog with
  | [] ->
      Printf.eprintf "fail: %s\n%!" (string_of_data (apply_subst s goal));
      raise NoClause
  | (_,clause) :: prog ->
      try
        let hd, subgoals, s = contextualize_hyp depth s clause in
        let s = unify goal hd s in
        SPY "selected"  prf_clause clause;
        let subgoals, s =
          List.fold_right (fun (d,p) (acc,s) ->
            let gl, s = contextualize_goal d s p in
            gl :: acc, s) subgoals ([],s) in
        s, List.flatten subgoals, prog
      with UnifFail _ -> select goal depth s prog

let pr_cur_goal g s fmt =
  match g with
  | `Atom goal -> prf_data [] fmt (apply_subst s goal)
  | `Unify(a,b) ->
        Format.eprintf "%a = %a"
          (prf_data []) (apply_subst s a) (prf_data []) (apply_subst s b)
  | `Custom(name,a) ->
        Format.eprintf "%s %a" name (prf_data []) (apply_subst s a)

let custom_tab = ref []
let register_custom n f = custom_tab := ("$"^n,f) :: !custom_tab
let custom name t s d p =
  try List.assoc name !custom_tab t s d p
  with Not_found -> raise(Invalid_argument ("custom "^name))

let rec run (prog : program) s ((depth,goal,extra) : goal) =
  let prog = extra @ prog in
  TRACE "run" (pr_cur_goal goal s)
  match goal with
  | `Atom goal ->
      let rec aux alternatives =
        let s, goals, alternatives = select goal depth s alternatives in
        SPY "sub" Subst.prf_subst s;
        try List.fold_left (run prog) s goals
        with NoClause -> aux alternatives in
      aux prog
  | `Unify(a,b) ->
      (try
        let s = unify a b s in
        SPY "sub" Subst.prf_subst s;
        s
      with UnifFail _ -> raise NoClause)
  | `Custom(name,a) ->
      try
        let s = custom name a s depth prog in
        SPY "sub" Subst.prf_subst s;
        s
      with UnifFail _ -> raise NoClause

let prepare_initial_goal g =
  let s = empty 1 in
  match g with
  | Sigma(n,g) ->
      let ms, s = fresh_uv n 0 s in
      fst(fold_map_premise 0 (fun i t _ -> contextualize i t ms,()) g ()), s
  | _ -> g, s

let run (p : program) (g : premise) =
  let g, s = prepare_initial_goal g in
  Format.eprintf "@[<hv2>goal:@ %a@]@\n%!"
    prf_goal (LP.map_premise (Red.nf s) g);
  let gls, s = contextualize_goal 0 s g in
  let s = List.fold_left (run p) s gls in
  g, s

(* vim:set foldmethod=marker: *)
