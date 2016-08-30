open Apak
open Term
open ArkPervasives
open BatPervasives

exception Nonlinear
exception Timeout

include Log.Make(struct let name = "ark.formula" end)
module L = Log

module type S = sig
  type t
  include Putil.Hashed.S with type t := t
  include Putil.OrderedMix with type t := t

  module T : Term.S

  val top : t
  val bottom : t
  val conj : t -> t -> t
  val disj : t -> t -> t
  val leqz : T.t -> t
  val eqz : T.t -> t
  val ltz : T.t -> t
  val atom : T.t atom -> t
  val eq : T.t -> T.t -> t
  val leq : T.t -> T.t -> t
  val geq : T.t -> T.t -> t
  val lt : T.t -> T.t -> t
  val gt : T.t -> T.t -> t
  val negate : t -> t

  val big_conj : t BatEnum.t -> t
  val big_disj : t BatEnum.t -> t

  val eval : ('a, T.t atom) formula_algebra -> t -> 'a
  val view : t -> (t, T.t atom) open_formula
  val conjuncts : t -> t BatEnum.t
  val disjuncts : t -> t BatEnum.t
  val is_linear : t -> bool

  val of_abstract : 'a T.D.t -> t
  val abstract : ?exists:(T.V.t -> bool) option ->
    ?solver:(Smt.solver) ->
    'a Apron.Manager.t ->
    t ->
    'a T.D.t
  val opt_abstract_limit : int ref
  val abstract_assign : 'a Apron.Manager.t ->
    'a T.D.t ->
    T.V.t ->
    T.t ->
    'a T.D.t
  val abstract_assume : 'a Apron.Manager.t -> 'a T.D.t -> t -> 'a T.D.t
  val boxify : T.t list -> t -> t

  val exists : (T.V.t -> bool) -> t -> t
  val exists_list : T.V.t list -> t -> t
  val opt_qe_strategy : ((T.V.t -> bool) -> t -> t) ref
  val qe_lme : (T.V.t -> bool) -> t -> t
  val qe_z3 : (T.V.t -> bool) -> t -> t
  val qe_cover : (T.V.t -> bool) -> t -> t
  val qe_partial : (T.V.t -> bool) -> t -> t
  val qe_trivial : (T.V.t -> bool) -> t -> t

  val simplify : (T.V.t -> bool) -> t -> t
  val simplify_z3 : (T.V.t -> bool) -> t -> t
  val simplify_dillig : (T.V.t -> bool) -> t -> t
  val simplify_dillig_nonlinear : (unit -> T.V.t) -> (T.V.t -> bool) -> t -> t
  val opt_simplify_strategy : ((T.V.t -> bool) -> t -> t) list ref
  val nudge : ?accuracy:int -> t -> t

  val linearize : (unit -> T.V.t) -> t -> t
  val linearize_apron : (unit -> T.V.t) -> t -> t
  val linearize_apron_dnf : (unit -> T.V.t) -> t -> t
  val linearize_opt : (unit -> T.V.t) -> t -> t
  val linearize_trivial : (unit -> T.V.t) -> t -> t
  val opt_linearize_strategy : ((unit -> T.V.t) -> t -> t) ref

  val of_smt : ?bound_vars:(T.V.t list) -> ?var_smt:(Smt.symbol -> T.t) -> Smt.ast -> t
  val to_smt : t -> Smt.ast
  val is_sat : t -> bool
  val implies : t -> t -> bool
  val equiv : t -> t -> bool
  val map : (T.t atom -> t) -> t -> t
  val subst : (T.V.t -> T.t) -> t -> t
  val select_disjunct : (T.V.t -> QQ.t) -> t -> t option
  val affine_hull : ?solver:(Smt.solver) -> t -> T.V.t list -> T.Linterm.t list
  val optimize : (T.t list) -> t -> Interval.interval list
  val disj_optimize : (T.t list) -> t -> Interval.interval list list

  val dnf_size : t -> int
  val nb_atoms : t -> int
  val size : t -> int

  val log_stats : Log.level -> unit

  val interpolate : t -> t -> t option

  val format_robust : Format.formatter -> t -> unit

  val var_bounds : (string -> typ -> T.V.t) ->
    T.V.t list ->
    T.V.t ->
    'a Apron.Manager.t ->
    t ->
    'a T.D.t

  module Syntax : sig
    val ( && ) : t -> t -> t
    val ( || ) : t -> t -> t
    val ( == ) : T.t -> T.t -> t
    val ( < ) : T.t -> T.t -> t
    val ( > ) : T.t -> T.t -> t
    val ( <= ) : T.t -> T.t -> t
    val ( >= ) : T.t -> T.t -> t
  end
end

module Make (T : Term.S) = struct
  open Hashcons

  module F = struct
    type t =
      | Or of t Hset.t
      | And of t Hset.t
      | Atom of T.t atom

    let hash = function
      | Or xs         -> Hashtbl.hash (Hset.hash xs, 0)
      | And xs        -> Hashtbl.hash (Hset.hash xs, 1)
      | Atom (LeqZ t) -> Hashtbl.hash (T.hash t, 2)
      | Atom (EqZ t)  -> Hashtbl.hash (T.hash t, 3)
      | Atom (LtZ t)  -> Hashtbl.hash (T.hash t, 4)

    let atom_equal x y = match x,y with
      | LeqZ s, LeqZ t
      | EqZ s, EqZ t
      | LtZ s, LtZ t -> T.equal s t
      | _, _ -> false

    let equal x y = match x,y with
      | Or xs, Or ys   -> Hset.equal xs ys
      | And xs, And ys -> Hset.equal xs ys
      | Atom a, Atom b -> atom_equal a b
      | _, _ -> false
  end

  open F
  module HC = Hashcons.Make(F)
  let formula_tbl = HC.create 200003
  let hashcons x = Log.time "formula:hashcons" (HC.hashcons formula_tbl) x

  type t = F.t hash_consed
  module T = T

  include Putil.MakeFmt(struct
      type a = t
      let rec format formatter phi =
        let open Format in
        match phi.node with
        | Or xs ->
          fprintf formatter "(@[<v 0>";
          ApakEnum.pp_print_enum_nobox
            ~pp_sep:(fun formatter () -> fprintf formatter "@;|| ")
            format
            formatter
            (Hset.enum xs);
          fprintf formatter "@])"
        | And xs ->
          fprintf formatter "(@[<v 0>";
          ApakEnum.pp_print_enum_nobox
            ~pp_sep:(fun formatter () -> fprintf formatter "@;&& ")
            format
            formatter
            (Hset.enum xs);
          fprintf formatter "@])"
        | Atom (LeqZ t) -> fprintf formatter "@[%a <= 0@]" T.format t
        | Atom (EqZ t) -> fprintf formatter "@[%a == 0@]" T.format t
        | Atom (LtZ t) -> fprintf formatter "@[%a < 0@]" T.format t
    end)
  module Compare_t = struct
    type a = t
    let compare x y = Pervasives.compare x.tag y.tag
  end
  let compare = Compare_t.compare
  let equal x y = x.tag == y.tag
  let hash x = x.hkey

  let top = hashcons (Atom (LeqZ T.zero))
  let bottom = hashcons (Atom (LeqZ T.one))

  let mk_and xs =
    if Hset.is_empty xs then top
    else if Hset.mem bottom xs then bottom
    else hashcons (And xs)

  let mk_or xs =
    if Hset.is_empty xs then bottom
    else if Hset.mem top xs then top
    else hashcons (Or xs)

  let conj phi psi =
    if phi.tag == top.tag then psi
    else if psi.tag == top.tag then phi
    else if phi.tag == bottom.tag || psi.tag == bottom.tag then bottom
    else begin match phi.node, psi.node with
      | (And xs, And ys) -> hashcons (And (Hset.union xs ys))
      | (And xs, _) -> hashcons (And (Hset.add psi xs))
      | (_, And xs) -> hashcons (And (Hset.add phi xs))
      | (_, _) -> hashcons (And (Hset.add phi (Hset.singleton psi)))
    end

(*
    else begin match phi.node, psi.node with
    | (And xs, And ys) -> hashcons (And (Hset.union xs ys))
    | (And xs, _) -> hashcons (And (Hset.add psi xs))
    | (_, And xs) -> hashcons (And (Hset.add phi xs))
    | (Or xs, Or ys) ->
      let common = Hset.inter xs ys in
      if Hset.is_empty common
      then hashcons (And (Hset.add phi (Hset.singleton psi)))
      else begin
	let phi = mk_or (Hset.diff xs common) in
	let psi = mk_or (Hset.diff ys common) in
	mk_and (Hset.add (mk_or (Hset.add phi (Hset.singleton psi))) common)
      end
    | (_, _) -> hashcons (And (Hset.add phi (Hset.singleton psi)))
    end
*)


  let disj phi psi =
    if phi.tag == bottom.tag then psi
    else if psi.tag == bottom.tag then phi
    else if phi.tag == top.tag || psi.tag == top.tag then top
    else hashcons (Or (Hset.add phi (Hset.singleton psi)))
(*
    else begin match phi.node, psi.node with
    | (Or xs, Or ys) -> hashcons (Or (Hset.union xs ys))
    | (Or xs, _) -> hashcons (Or (Hset.add psi xs))
    | (_, Or xs) -> hashcons (Or (Hset.add phi xs))
    | (And xs, And ys) ->
      let common = Hset.inter xs ys in
      if Hset.is_empty common
      then hashcons (Or (Hset.add phi (Hset.singleton psi)))
      else begin
	let phi = mk_and (Hset.diff xs common) in
	let psi = mk_and (Hset.diff ys common) in
	mk_and (Hset.add (mk_or (Hset.add phi (Hset.singleton psi))) common)
      end
    | (_, _) -> hashcons (Or (Hset.add phi (Hset.singleton psi)))
    end*)

  let leqz term =
    match T.to_const term with
    | Some k -> if QQ.leq k QQ.zero then top else bottom
    | _ -> hashcons (Atom (LeqZ term))
  let eqz term =
    match T.to_const term with
    | Some k -> if QQ.equal k QQ.zero then top else bottom
    | _ -> hashcons (Atom (EqZ term))
  let ltz term =
    match T.to_const term with
    | Some k -> if QQ.lt k QQ.zero then top else bottom
    | _ ->
      if T.typ term == TyInt then hashcons (Atom (LeqZ (T.add term T.one)))
      else hashcons (Atom (LtZ term))

  let atom = function
    | LeqZ t -> leqz t
    | EqZ t  -> eqz t
    | LtZ t  -> ltz t

  let eq s t = eqz (T.sub s t)
  let leq s t = leqz (T.sub s t)
  let geq s t = leqz (T.sub t s)
  let lt s t = ltz (T.sub s t)
  let gt s t = ltz (T.sub t s)

  module M = Memo.Make(struct
      type t = F.t hash_consed
      let hash t = t.hkey
      let equal s t = s.tag == t.tag
    end)

  let eval alg =
    M.memo_recursive ~size:991 (fun eval x ->
        match x.node with
        | Or xs ->
          let e = Hset.enum xs in
          begin match BatEnum.get e with
            | Some elt ->
              BatEnum.fold (fun x y -> alg (OOr (x, eval y))) (eval elt) e
            | None -> alg (OAtom (LeqZ T.one))
          end
        | And xs ->
          let e = Hset.enum xs in
          begin match BatEnum.get e with
            | Some elt ->
              BatEnum.fold (fun x y -> alg (OAnd (x, eval y))) (eval elt) e
            | None -> alg (OAtom (LeqZ T.zero))
          end
        | Atom atom -> alg (OAtom atom))

  let view t = match t.node with
    | Atom atom -> OAtom atom
    | And xs ->
      (* todo: skip enumerations; write functions in hset to make this more
         	 efficient *)
      let e = Hset.enum xs in
      begin match BatEnum.count e with
        | 0 -> OAtom (LeqZ T.zero)
        | 1 -> assert false (* this should have been promoted! *)
        | 2 -> OAnd (BatEnum.get_exn e, BatEnum.get_exn e)
        | _ -> OAnd (BatEnum.get_exn e, hashcons (And (Hset.of_enum e)))
      end
    | Or xs ->
      let e = Hset.enum xs in
      begin match BatEnum.count e with
        | 0 -> OAtom (LeqZ T.one)
        | 1 -> assert false (* this should have been promoted! *)
        | 2 -> OOr (BatEnum.get_exn e, BatEnum.get_exn e)
        | _ -> OOr (BatEnum.get_exn e, hashcons (Or (Hset.of_enum e)))
      end

  let conjuncts t =
    if equal t top then BatEnum.empty () else
      match t.node with
      | Atom _ | Or _ -> BatEnum.singleton t
      | And xs -> Hset.enum xs

  let disjuncts t =
    if equal t bottom then BatEnum.empty () else
      match t.node with
      | Atom _ | And _ -> BatEnum.singleton t
      | Or xs -> Hset.enum xs

  let is_linear phi =
    let alg = function
      | OAtom (LtZ t)
      | OAtom (LeqZ t)
      | OAtom (EqZ t) -> if T.is_linear t then () else raise Nonlinear
      | _ -> ()
    in
    try eval alg phi; true
    with Nonlinear -> false

  let to_smt =
    let alg = function
      | OAtom (LeqZ t) -> Smt.mk_le (T.to_smt t) (Smt.const_int 0)
      | OAtom (LtZ t) -> Smt.mk_lt (T.to_smt t) (Smt.const_int 0)
      | OAtom (EqZ t) -> Smt.mk_eq (T.to_smt t) (Smt.const_int 0)
      | OAnd (x, y) -> Smt.conj x y
      | OOr (x, y) -> Smt.disj x y
    in
    eval alg

  let log_stats (level : Log.level) =
    let (length, count, total, min, median, max) = HC.stats formula_tbl in
    Log.log ~level:level "----------------------------\n Formula stats";
    Log.logf ~level:level "Length:\t\t%d" length;
    Log.logf ~level:level "Count:\t\t%d" count;
    Log.logf ~level:level "Total size:\t%d" total;
    Log.logf ~level:level "Min bucket:\t%d" min;
    Log.logf ~level:level "Median bucket:\t%d" median;
    Log.logf ~level:level "Max bucket:\t%d" max

  let negate_atom = function
    | LeqZ t -> ltz (T.neg t)
    | LtZ t -> leqz (T.neg t)
    | EqZ t -> disj (ltz t) (ltz (T.neg t))

  let negate =
    let alg = function
      | OOr (x, y) -> conj x y
      | OAnd (x, y) -> disj x y
      | OAtom atom -> negate_atom atom
    in
    eval alg

  let map f =
    let alg = function
      | OOr (phi, psi) -> disj phi psi
      | OAnd (phi, psi) -> conj phi psi
      | OAtom atom -> f atom
    in
    eval alg

  let subst sigma =
    let term_subst = T.subst sigma in (* Build memo table here *)
    let subst_atom = function
      | LtZ t -> ltz (term_subst t)
      | LeqZ t -> leqz (term_subst t)
      | EqZ t -> eqz (term_subst t)
    in
    map subst_atom

  let of_smt ?(bound_vars=[]) ?(var_smt=(T.var % T.V.of_smt)) ast =
    let open Z3 in
    let open Z3enums in
    let smt_term vs = T.of_smt (List.nth vs) ~var_smt:var_smt in
    let rec of_smt vars ast =
      match AST.get_ast_kind (Expr.ast_of_expr ast) with
      | APP_AST -> begin
          let decl = Expr.get_func_decl ast in
          let args = BatList.enum (Expr.get_args ast) in
          match FuncDecl.get_decl_kind decl with
          | OP_TRUE -> top
          | OP_FALSE -> bottom
          | OP_AND ->
            BatEnum.fold conj top (BatEnum.map (of_smt vars) args)
          | OP_OR ->
            BatEnum.fold disj bottom (BatEnum.map (of_smt vars) args)
          | OP_NOT -> begin
              match BatList.of_enum (BatEnum.map (of_smt vars) args) with
              | [phi] -> negate phi
              | _ -> assert false
            end
          | OP_EQ -> begin
              match BatList.of_enum (BatEnum.map (smt_term vars) args) with
              | [x;y] -> eq x y
              | _ -> assert false
            end
          | OP_LE -> begin
              match BatList.of_enum (BatEnum.map (smt_term vars) args) with
              | [x;y] -> leq x y
              | _ -> assert false
            end
          | OP_GE -> begin
              match BatList.of_enum (BatEnum.map (smt_term vars) args) with
              | [x;y] -> geq x y
              | _ -> assert false
            end
          | OP_LT -> begin
              match BatList.of_enum (BatEnum.map (smt_term vars) args) with
              | [x;y] -> lt x y
              | _ -> assert false
            end
          | OP_GT -> begin
              match BatList.of_enum (BatEnum.map (smt_term vars) args) with
              | [x;y] -> gt x y
              | _ -> assert false
            end
          | _ -> assert false
        end
      | QUANTIFIER_AST ->
        let ast = Quantifier.quantifier_of_expr ast in
        let new_vars =
          List.map T.V.of_smt (Quantifier.get_bound_variable_names ast)
        in
        let vars = List.append new_vars vars in
        of_smt vars (Quantifier.get_body ast)
      | NUMERAL_AST
      | VAR_AST
      | FUNC_DECL_AST
      | SORT_AST
      | UNKNOWN_AST -> assert false
    in
    of_smt bound_vars ast

  let of_goal g =
    let open Z3 in
    let formulae = BatEnum.map of_smt (BatList.enum (Goal.get_formulas g)) in
    BatEnum.fold conj top formulae

  let of_apply_result result =
    let open Z3 in
    let formulae =
      BatList.enum (List.map of_goal (Tactic.ApplyResult.get_subgoals result))
    in
    BatEnum.fold conj top formulae

  let is_sat phi =
    let s = new Smt.solver in
    s#assrt (to_smt phi);
    match s#check () with
    | Smt.Sat   -> true
    | Smt.Unsat -> false
    | Smt.Undef -> raise Timeout

  let implies phi psi =
    let s = new Smt.solver in
    s#assrt (to_smt phi);
    s#assrt (Smt.mk_not (to_smt psi));
    match s#check () with
    | Smt.Sat   -> false
    | Smt.Unsat -> true
    | Smt.Undef -> raise Timeout

  let equiv phi psi =
    let s = new Smt.solver in
    let phi_smt = to_smt phi in
    let psi_smt = to_smt psi in
    s#assrt (Smt.disj
               (Smt.conj phi_smt (Smt.mk_not psi_smt))
               (Smt.conj (Smt.mk_not phi_smt) psi_smt));
    match s#check () with
    | Smt.Sat   -> false
    | Smt.Unsat -> true
    | Smt.Undef -> begin
        Log.errorf "Timeout in equivalence check:@\n%a@\n  =  @\n%a"
          format phi
          format psi;
        raise Timeout
      end

  let big_disj = BatEnum.fold disj bottom
  let big_conj = BatEnum.fold conj top

  (* A strange term evaluates to different things according to T.eval and
     m#eval_qq.  For debugging purposes only: strange terms should not
     exist *)
  let strange_term m t =
    let x = T.evaluate (m#eval_qq % T.V.to_smt) t in
    let y = m#eval_qq (T.to_smt t) in
    if not (QQ.equal x y) then begin
      Log.errorf "Found a strange term: %a" T.format t;
      assert false
    end

  (* A strange formula is one that contains a strange term.  For debugging
     purposes only: strange formulae should not exist *)
  let strange_formula m phi =
    let f = function
      | OAtom (LeqZ t) | OAtom (LtZ t) | OAtom (EqZ t) -> strange_term m t
      | _ -> ()
    in
    eval f phi

  (** [select_disjunct m phi] selects a clause [psi] in the disjunctive normal
      form of [psi] such that [m |= psi] *)
  let select_disjunct m phi =
    let f = function
      | OAtom (LeqZ t) ->
        (try
           if QQ.leq (T.evaluate m t) QQ.zero then Some (leqz t) else None
         with Divide_by_zero -> None)
      | OAtom (LtZ t) ->
        (try
           if QQ.lt (T.evaluate m t) QQ.zero then Some (ltz t) else None
         with Divide_by_zero -> None)

      | OAtom (EqZ t) ->
        (try
           if QQ.equal (T.evaluate m t) QQ.zero then Some (eqz t) else None
         with Divide_by_zero -> None)
      | OAnd (Some phi, Some psi) -> Some (conj phi psi)
      | OAnd (_, _) -> None
      | OOr (x, None) | OOr (_, x) -> x
    in
    eval f phi

  (** [unsat_residual m phi] replaces every atom in [phi] which the model [m]
      satisfies with [true] (and leaves unsatisfied atoms unchanged). *)
  let unsat_residual m phi =
    let f = function
      | OAtom (LeqZ t) ->
        if QQ.leq (T.evaluate m t) QQ.zero then top else leqz t
      | OAtom (LtZ t) ->
        if QQ.lt (T.evaluate m t) QQ.zero then top else ltz t
      | OAtom (EqZ t) ->
        if QQ.equal (T.evaluate m t) QQ.zero then top else eqz t
      | OAnd (phi, psi) -> conj phi psi
      | OOr (phi, psi) -> disj phi psi
    in
    eval f phi

  module VarSet = Putil.Set.Make(T.V)
  module VarMap = Putil.Map.Make(T.V)
  module D = T.D

  let term_free_vars term =
    let f = function
      | OVar v -> VarSet.singleton v
      | OConst _ -> VarSet.empty
      | OAdd (x,y) | OMul (x,y) | ODiv (x,y) | OMod (x,y) -> VarSet.union x y
      | OFloor x -> x
    in
    T.eval f term

  let formula_free_vars phi =
    let f = function
      | OOr (x,y) | OAnd (x,y) -> VarSet.union x y
      | OAtom (LeqZ t) | OAtom (EqZ t) | OAtom (LtZ t) -> term_free_vars t
    in
    eval f phi

  let of_tcons env tcons =
    let open Apron in
    let open Tcons0 in
    let t = T.of_apron env tcons.texpr0 in
    match tcons.typ with
    | EQ      -> eqz t
    | SUPEQ   -> leqz (T.neg t)
    | SUP     -> ltz (T.neg t)
    | DISEQ   -> negate (eqz t)
    | EQMOD _ -> assert false (* todo *)

  let mk_env phi = D.Env.of_enum (VarSet.enum (formula_free_vars phi))

  let dnf_size phi =
    let alg = function
      | OOr (x, y) -> x + y
      | OAnd (x, y) -> x * y
      | _ -> 1
    in
    eval alg phi

  let nb_atoms phi =
    let alg = function
      | OOr (x, y) | OAnd (x, y) -> x + y
      | _ -> 1
    in
    eval alg phi

  let size phi =
    let alg = function
      | OOr (x, y) | OAnd (x, y) -> x + y + 1
      | _ -> 1
    in
    eval alg phi

  let atom_smt = function
    | LeqZ t -> Smt.mk_le (T.to_smt t) (Smt.const_int 0)
    | LtZ t -> Smt.mk_lt (T.to_smt t) (Smt.const_int 0)
    | EqZ t -> Smt.mk_eq (T.to_smt t) (Smt.const_int 0)

  let rec simplify_children star s children =
    let f psi = s#assrt (star (to_smt psi)) in
    let changed = ref false in
    let rec go simplified = function
      | [] -> simplified
      | (phi::phis) ->
        s#push ();
        List.iter f simplified;
        List.iter f phis;
        let simple_phi = simplify_dillig_impl phi s in
        s#pop ();
        if not (equal phi simple_phi) then changed := true;
        go (simple_phi::simplified) phis
    in
    let rec fix children =
      let simplified = go [] children in
      if !changed then begin
        changed := false;
        fix simplified
      end else simplified
    in
    fix (BatList.of_enum (Hset.enum children))

  and simplify_dillig_impl phi s =
    match phi.node with
    | Atom at ->
      s#push ();
      s#assrt (atom_smt at);
      let simplified =
        match s#check () with
        | Smt.Undef -> atom at
        | Smt.Unsat -> bottom
        | Smt.Sat ->
          s#pop ();
          s#push ();
          s#assrt (Smt.mk_not (atom_smt at));
          match s#check () with
          | Smt.Undef -> atom at
          | Smt.Unsat -> top
          | Smt.Sat -> atom at
      in
      s#pop ();
      simplified
    | Or xs -> big_disj (BatList.enum (simplify_children Smt.mk_not s xs))
    | And xs -> big_conj (BatList.enum (simplify_children (fun x -> x) s xs))

  let simplify_dillig _ phi = simplify_dillig_impl phi (new Smt.solver)

  module Polyhedron = struct
    module L = T.Linterm
    type t = { eq : L.t list;
               leq : L.t list }

    let dimensions polyhedron =
      let linterm_dimensions vec =
        L.var_bindings vec /@ fst |> VarSet.of_enum
      in
      let add_dim dims vec =
        VarSet.union (linterm_dimensions vec) dims
      in
      List.fold_left add_dim VarSet.empty (polyhedron.eq@polyhedron.leq)

    let enum polyhedron =
      BatEnum.append
        (BatList.enum polyhedron.eq /@ (fun t -> `EqZero t))
        (BatList.enum polyhedron.leq /@ (fun t -> `LeqZero t))

    let format formatter p =
      let pp_elt formatter = function
        | `EqZero t -> Format.fprintf formatter "%a = 0" L.format t
        | `LeqZero t -> Format.fprintf formatter "%a <= 0" L.format t
      in
      let pp_sep formatter () = Format.fprintf formatter "@;" in
      Format.fprintf formatter "@[<v 0>%a@]"
        (ApakEnum.pp_print_enum_nobox ~pp_sep pp_elt) (enum p)

    let conjoin x y =
      { eq = x.eq @ y.eq;
        leq = x.leq @ y.leq }

    let nonzero_coeff v t = not (QQ.equal (L.var_coeff v t) QQ.zero)

    let of_atom =
      let linearize t =
        match T.to_linterm t with
        | Some lt -> lt
        | None -> raise Nonlinear
      in
      function
      | LeqZ t -> { eq = []; leq = [linearize t] }
      | LtZ t -> { eq = []; leq = [linearize t] }
      | EqZ t -> { eq = [linearize t]; leq = [] }

    let of_formula phi =
      let alg = function
        | OAtom at -> of_atom at
        | OAnd (p, q) -> conjoin p q
        | OOr (_, _) -> invalid_arg "Polyhedron.of_formula"
      in
      eval alg phi

    let to_formula p =
      let eqs =
        BatEnum.map (fun t -> atom (EqZ (T.of_linterm t))) (BatList.enum p.eq)
      in
      let leqs =
        BatEnum.map (fun t -> atom (LeqZ (T.of_linterm t))) (BatList.enum p.leq)
      in
      big_conj (BatEnum.append eqs leqs)

    let fourier_motzkin v p =
      try
        let eq_term = BatList.find (nonzero_coeff v) p.eq in
        let (a, t) = L.pivot (AVar v) eq_term in
        let replacement = L.scalar_mul (QQ.inverse (QQ.negate a)) t in
        let replace t =
          let (a, rest) = L.pivot (AVar v) t in
          if QQ.equal a QQ.zero then
            Some t
          else
            let new_term = L.add (L.scalar_mul a replacement) rest in
            match L.const_of new_term with
            | Some k ->
              assert (QQ.leq k QQ.zero);
              None
            | None -> Some new_term
        in
        { eq = BatList.filter_map replace p.eq;
          leq = BatList.filter_map replace p.leq }
      with Not_found ->
        let (occ, rest) = List.partition (nonzero_coeff v) p.leq in
        let normalize term =
          (* a*v + t <= 0 *)
          let (a, t) = L.pivot (AVar v) term in
          let toa = L.scalar_mul (QQ.inverse (QQ.negate a)) t in
          if QQ.lt a QQ.zero then
            `Lower toa
          else
            `Upper toa
        in
        let (lower, upper) =
          List.fold_left (fun (lower, upper) t ->
              match normalize t with
              | `Lower t -> (t::lower, upper)
              | `Upper t -> (lower, t::upper))
            ([],[])
            occ
        in
        let fm_occ =
          ApakEnum.cartesian_product (BatList.enum lower) (BatList.enum upper)
          /@ (fun (lower, upper) -> L.sub lower upper)
          |> BatList.of_enum
        in
        { eq = p.eq;
          leq = fm_occ@rest }

    let occurrence_map vars p =
      let f m t =
        let g m (var, coeff) =
          if VarSet.mem var vars then begin
            let (pos, neg) =
              try VarMap.find var m
              with Not_found -> (0, 0)
            in
            let (pos, neg) =
              if QQ.leq coeff QQ.zero then (pos, neg + 1)
              else (pos + 1, neg)
            in
            VarMap.add var (pos, neg) m
          end else
            m
        in
        BatEnum.fold g m (L.var_bindings t)
      in
      List.fold_left f VarMap.empty p.leq

    let h_val (pos, neg) = pos*neg - (pos + neg)
    let pick_min occ_map =
      let f (min_v, min_h) (v, (pos, neg)) =
        let h = h_val (pos, neg) in
        if h < min_h then (v, h) else (min_v, min_h)
      in
      let e = VarMap.enum occ_map in
      let (v, (pos, neg)) = BatEnum.get_exn e in
      fst (BatEnum.fold f (v, h_val (pos, neg)) e)

    let vars p =
      let add_vars vs t =
        BatEnum.fold (fun vs (d, _) -> VarSet.add d vs) vs (L.var_bindings t)
      in
      List.fold_left
        add_vars
        (List.fold_left add_vars VarSet.empty p.eq)
        p.leq

    let to_apron env man p =
      let open Apron in
      let open D in
      let apron_leq t =
        Lincons0.make (T.apron_of_linterm env (L.negate t)) Lincons0.SUPEQ
      in
      let apron_eq t =
        Lincons0.make (T.apron_of_linterm env t) Lincons0.EQ
      in
      let constraints =
        (List.map apron_eq p.eq) @ (List.map apron_leq p.leq)
      in
      { prop =
          Abstract0.of_lincons_array
            man
            (Env.int_dim env)
            (Env.real_dim env)
            (Array.of_list constraints);
        env = env }
    let to_apron env man p = Log.time "to_apron" (to_apron env man) p

    let term_to_smt =
      let to_smt = function
        | AVar v -> T.V.to_smt v
        | AConst -> Smt.const_int 1
      in
      L.to_smt to_smt Smt.const_qq

    let add_leq (s, p) t =
      s#push ();
      s#assrt (Smt.mk_gt (term_to_smt t) (Smt.const_int 0));
      match s#check () with
      | Smt.Sat | Smt.Undef ->
        begin
          s#pop ();
          s#assrt (Smt.mk_le (term_to_smt t) (Smt.const_int 0));
          (s, { p with leq = t::p.leq })
        end
      | Smt.Unsat ->
        (s#pop (); (s, p))

    (* Try to project out a set of variables from a polyhedron, but leave
       variables that are expensive to eliminate. *)
    let rec try_fme vars p =
      let occ_map = occurrence_map vars p in
      if VarMap.is_empty occ_map then p
      else begin
        let v = pick_min occ_map in
        let (pos, neg) = VarMap.find v occ_map in
        if h_val (pos, neg) <= 10 (* arbitrary... *)
        then try_fme (VarSet.remove v vars) (fourier_motzkin v p)
        else p
      end
    let try_fme vars p =
      Log.time "Polyhedron.try_fme" (try_fme vars) p

    let simplify_minimal p =
      let s = new Smt.solver in
      let assrt t =
        s#assrt (Smt.mk_le (term_to_smt t) (Smt.const_int 0))
      in
      let rec go left = function
        | [] -> left
        | (t::right) ->
          s#push ();
          List.iter assrt right;
          s#assrt (Smt.mk_gt (term_to_smt t) (Smt.const_int 0));
          match s#check () with
          | Smt.Sat | Smt.Undef ->
            begin
              s#pop ();
              assrt t;
              go (t::left) right
            end
          | Smt.Unsat ->
            begin
              s#pop ();
              go left right
            end
      in
      { eq = p.eq; leq = go [] p.leq }

    let simplify p =
      let s = new Smt.solver in
      snd (List.fold_left add_leq (s, { p with leq = [] }) p.leq)

    let simplify p =
      Log.time "Polyhedron.simplify" simplify p

    (* Given a valuation m and a (topologically closed) formula phi in LIRA,
       find a cube p of the DNF of phi such that m |= p |= phi.  Similar to
       select_disjunct, except expressed as a polyhedron rather than a
       formula. *)
    let select m phi =
      M.memo_recursive ~size:991 (fun eval x ->
          match x.node with
          | Or xs ->
            begin
              try
                Some (BatEnum.find_map eval (Hset.enum xs))
              with Not_found -> None
            end
          | And xs ->
            let e = Hset.enum xs in
            let rec go p =
              match BatEnum.get e with
              | Some elt ->
                begin
                  match eval elt with
                  | Some elt_p -> go (conjoin p elt_p)
                  | None -> None
                end
              | None -> Some p
            in
            go { eq = []; leq = [] }
          | Atom atom ->
            try
              match atom with
              | LeqZ t ->
                if QQ.leq (T.evaluate m t) QQ.zero then
                  Some (of_atom (LeqZ t))
                else
                  None
              | LtZ t ->
                if QQ.lt (T.evaluate m t) QQ.zero then
                  Some (of_atom (LtZ t))
                else
                  None
              | EqZ t ->
                if QQ.equal (T.evaluate m t) QQ.zero then
                  Some (of_atom (EqZ t))
                else
                  None
            with Divide_by_zero -> None)
        phi

    (* Model-guided term selection based on Loos-Weispfenning *)
    let select_term m x polyhedron =
      let module L = T.Linterm in
      let x_val = T.evaluate m (T.var x) in
      let term_val = T.evaluate m % T.of_linterm in
      try
        let (a, t) =
          L.pivot (AVar x) (BatList.find (nonzero_coeff x) polyhedron.eq)
        in
        assert (not (QQ.equal a QQ.zero));
        `Term (L.scalar_mul (QQ.inverse (QQ.negate a)) t)
      with Not_found ->
        let lower_bound t =
          (* constraint is a*x + t <= 0 *)
          let (a, t) = L.pivot (AVar x) t in
          if QQ.geq a QQ.zero then
            None
          else
            Some (L.scalar_mul (QQ.inverse (QQ.negate a)) t)
        in
        match BatList.filter_map lower_bound polyhedron.leq with
        | [] -> `MinusInfinity
        | (t::ts) ->
          let glb =
            List.fold_left (fun glb t ->
                if QQ.lt (term_val glb) (term_val t) then t else glb)
              t
              ts
          in
          if QQ.equal (term_val glb) x_val then
            `Term glb
          else
            `PlusEpsilon glb

    (* Model-guided projection of a polyhedron.  Given a point m within a
       polyhedron p and a set of dimension xs, compute a polyhedron q such
       that m|_xs is within q, and q is a subset of p|_xs (using |_xs to
       denote projection of dimensions xs) *)
    let local_project m xs polyhedron =
      (* Replace x with replacement in term representing an (in)equality
         constraint.  Return None if the resulting (in)equality is trivial. *)
      let replace_term x replacement term =
        let (a, t) = L.pivot (AVar x) term in
        let replaced = L.add (L.scalar_mul a replacement) t in
        match L.const_of replaced with
        | Some k ->
          assert (QQ.leq k QQ.zero);
          None
        | None -> Some replaced
      in
      (* Project a single variable *)
      let project_one x polyhedron =
        (* occ is the set of equations involving x, nonocc is the set of
           equations that don't *)
        let (occ, nonocc) = List.partition (nonzero_coeff x) polyhedron.eq in
        match occ with
        | (term::rest) ->
          (* If x is involved in an equation a*x + t = 0, replace x with -t/a
             everywhere *)
          let (a, t) = L.pivot (AVar x) term in
          let toa = L.scalar_mul (QQ.inverse (QQ.negate a)) t in
          { eq =
              List.fold_left (fun eqs eq ->
                  match replace_term x toa eq with
                  | Some eq -> eq::eqs
                  | None -> eqs)
                nonocc
                rest;
            leq = BatList.filter_map (replace_term x toa) polyhedron.leq }
        | [] ->
          (* If no equations involve x, find a least upper bound or greatest
             lower bound for x *)
          let (occ, nonocc) = List.partition (nonzero_coeff x) polyhedron.leq in
          let (lower, upper) =
            List.fold_left (fun (lower, upper) t ->
                let (a, t) = L.pivot (AVar x) t in
                let bound = L.scalar_mul (QQ.inverse (QQ.negate a)) t in
                (* constraint is a*x + t <= 0, which is either x <= bound or
                   bound <= x, depending on the sign of a *)
                if QQ.gt a QQ.zero then
                  (lower, bound::upper)
                else
                  (bound::lower, upper))
              ([], [])
              occ
          in
          match lower, upper with
          | [], _ | _, [] ->
            (* no lower bound or no upper bounds -> just remove all
               constraints involving x *)
            { eq = polyhedron.eq; leq = nonocc }
          | (lt::lower), (ut::upper) ->
            let term_val = T.evaluate_linterm m in
            if List.length lower < List.length upper then
              let glb =
                List.fold_left (fun glb t ->
                    if QQ.lt (term_val glb) (term_val t) then t else glb)
                  lt
                  lower
              in
              { eq = polyhedron.eq;
                leq = (BatList.filter_map (replace_term x glb) occ)@nonocc }
            else
              let lub =
                List.fold_left (fun lub t ->
                    if QQ.lt (term_val t) (term_val lub) then t else lub)
                  ut
                  upper
              in
              { eq = polyhedron.eq;
                leq = (BatList.filter_map (replace_term x lub) occ)@nonocc }
      in
      VarSet.fold project_one xs polyhedron

    let local_project m xs polyhedron =
      Log.time "local_project" (local_project m xs) polyhedron

    (* Check whether a given point belongs to a polyhedron *)
    let mem m polyhedron =
      List.for_all
        (fun t -> QQ.equal (T.evaluate_linterm m t) QQ.zero)
        polyhedron.eq
      && List.for_all
        (fun t -> QQ.leq (T.evaluate_linterm m t) QQ.zero)
        polyhedron.leq
  end

  let top_closure =
    map (function
        | LtZ t -> atom (LeqZ t)
        | at -> atom at)

  (* [lazy_dnf join bottom top prop_to_smt phi] computes an abstraction of phi
     by lazily computing its disjunctive normal form.
     [join] : [abstract -> purely conjunctive formula -> abstract]
         [join abstract psi] computes an abstract property which
         overapproximates both abstract and psi.
     [bottom] : [abstract]
         Represents false
     [top] : [abstract]
         Represents true
     [prop_to_smt] : [abstract -> smt formula]
         Convert an abstract property to an SMT formula
     [phi] : [formula]
         The formula to abstract
  *)
  let lazy_dnf ~join ~bottom ~top prop_to_smt phi =
    let s = new Smt.solver in
    let disjuncts = ref 0 in
    let rec go prop =
      s#push ();
      s#assrt (Smt.mk_not (prop_to_smt prop));
      match Log.time "lazy_dnf/sat" s#check () with
      | Smt.Unsat -> prop
      | Smt.Undef ->
        begin
          Log.errorf "lazy_dnf timed out (%d disjuncts)" (!disjuncts);
          raise Timeout
        end
      | Smt.Sat -> begin
          let m = s#get_model () in
          s#pop ();
          incr disjuncts;
          logf "[%d] lazy_dnf" (!disjuncts);
          let disjunct = match select_disjunct (m#eval_qq % T.V.to_smt) phi with
            | Some d -> d
            | None -> assert false
          in
          go (join prop disjunct)
        end
    in
    s#assrt (to_smt phi);
    go bottom

  (* Convert a *conjunctive* formula into a list of apron tree constraints *)
  let to_apron man env phi =
    let open Apron in
    let open D in
    let to_apron = T.to_apron env in
    let alg = function
      | OAtom (LeqZ t) -> [Tcons0.make (to_apron (T.neg t)) Tcons0.SUPEQ]
      | OAtom (LtZ t) -> [Tcons0.make (to_apron (T.neg t)) Tcons0.SUP]
      | OAtom (EqZ t) -> [Tcons0.make (to_apron t) Tcons0.EQ]
      | OAnd (phi, psi) -> phi @ psi
      | OOr (_, _) -> assert false
    in
    { prop =
        Abstract0.of_tcons_array
          man
          (Env.int_dim env)
          (Env.real_dim env)
          (Array.of_list (eval alg phi));
      env = env }
  let to_apron man env phi =
    Log.time "to_apron" (to_apron man env) phi

  let of_abstract x =
    let open Apron in
    let open D in
    let man = Abstract0.manager x.prop in
    let tcons = BatArray.enum (Abstract0.to_tcons_array man x.prop) in
    big_conj (BatEnum.map (of_tcons x.env) tcons)

  let abstract ?exists:(p=None) man phi =
    let open D in
    let env = mk_env phi in
    let env_proj = match p with
      | Some p -> D.Env.filter p env
      | None   -> env
    in
    let join prop disjunct =
      let new_prop = match p with
        | Some p ->
          Log.time "Projection" (D.exists man p) (to_apron man env disjunct)
        | None   -> to_apron man env disjunct
      in
      D.join prop new_prop
    in
    let (top, bottom) = (D.top man env_proj, D.bottom man env_proj) in
    try
      Log.time "Abstraction"
        (lazy_dnf ~join:join ~bottom:bottom ~top:top (to_smt % of_abstract))
        phi
    with Timeout -> begin
        Log.errorf "Symbolic abstraction timed out; returning top";
        top
      end

  let abstract_assign man x v t =
    let open Apron in
    let open D in
    let vars = VarSet.add v (term_free_vars t) in
    let x = D.add_vars (VarSet.enum vars) x in
    { prop =
        Abstract0.assign_texpr_array
          man
          x.prop
          [| Env.dim_of_var x.env v|]
          [| T.to_apron x.env t |]
          None;
      env = x.env }

  let abstract_assume man x phi = abstract man (conj (of_abstract x) phi)

  (****************************************************************************)
  (* Quantifier elimination                                                   *)
  (****************************************************************************)

  let qe_trivial p phi =
    let f = function
      | EqZ t ->
        if VarSet.exists (not % p) (term_free_vars t) then top
        else eqz t
      | LeqZ t ->
        if VarSet.exists (not % p) (term_free_vars t) then top
        else leqz t
      | LtZ t ->
        if VarSet.exists (not % p) (term_free_vars t) then top
        else ltz t
    in
    map f phi

  let qe_lme p phi =
    let man = NumDomain.polka_strict_manager () in
    let env = mk_env phi in
    logf "Quantifier elimination [dim: %d, target: %d]"
      (D.Env.dimension env)
      (D.Env.dimension (D.Env.filter p env));
    let join psi disjunct =
      logf "Polytope projection [sides: %d]"
        (nb_atoms disjunct);
      let projection =
        Log.time "Polytope projection"
          (fun () -> of_abstract (D.exists man p (to_apron man env disjunct)))
          ()
      in
      logf "Projected polytope sides: %d" (nb_atoms projection);
      disj psi projection
    in
    try lazy_dnf ~join:join ~bottom:bottom ~top:top to_smt phi
    with Timeout ->
      Log.errorf "Quantifier elimination timed out.  Trying qe_trivial.";
      qe_trivial p phi

  let qe_z3 p phi =
    let open Z3 in
    let fv = formula_free_vars phi in
    let vars = BatList.of_enum (BatEnum.filter (not % p) (VarSet.enum fv)) in
    let ctx = Smt.get_context () in
    let solve = Tactic.mk_tactic ctx "qe" in
    let simpl = Tactic.mk_tactic ctx "simplify" in
    let qe = Tactic.and_then ctx solve simpl [] in
    let g = Goal.mk_goal ctx false false false in
    Goal.add g [Smt.mk_exists_const (List.map T.V.to_smt vars) (to_smt phi)];
    of_apply_result (Tactic.apply qe g None)

  (* Collapse nested conjunctions & disjunctions *)
  let flatten phi =
    let rec flatten_and phi =
      match phi.node with
      | And xs ->
        let f x xs = Hset.union (flatten_and x) xs in
        Hset.fold f xs Hset.empty
      | Or _ -> Hset.singleton (hashcons (Or (flatten_or phi)))
      | Atom at -> Hset.singleton phi
    and flatten_or phi =
      match phi.node with
      | Or xs ->
        let f x xs = Hset.union (flatten_or x) xs in
        Hset.fold f xs Hset.empty
      | And xs -> Hset.singleton (hashcons (And (flatten_and phi)))
      | Atom at -> Hset.singleton phi
    in
    match phi.node with
    | And _ -> hashcons (And (flatten_and phi))
    | Or _ -> hashcons (Or (flatten_or phi))
    | Atom at -> phi

  let orient_equation p t =
    match T.to_linterm t with
    | None -> None
    | Some lt ->
      try
        let (v, coeff) =
          BatEnum.find (p % fst) (T.Linterm.var_bindings lt)
        in
        let rhs =
          T.div
            (T.of_linterm (T.Linterm.add_term (AVar v) (QQ.negate coeff) lt))
            (T.const (QQ.negate coeff))
        in
        Some (v, rhs)
      with Not_found -> None

  exception Is_top
  let qe_partial p phi =

    (* Find the set of variables which appear in a formula and which are bound
       by the quantifier *)
    let bound_vars =
      let bv_alg = function
        | OOr (x,y) | OAnd (x,y) -> VarSet.union x y
        | OAtom (LeqZ t) | OAtom (EqZ t) | OAtom (LtZ t) ->
          VarSet.filter (not % p) (term_free_vars t)
      in
      Log.time "Bound vars" (eval bv_alg)
    in

    let phi_bound_vars = bound_vars phi in
    logf ~level:`trace "QE_PARTIAL: %a" VarSet.format phi_bound_vars;
    let mk_subst rewrite = fun x ->
      try T.V.Map.find x rewrite with Not_found -> T.var x
    in
    let rewrite_varset rewrite varset =
      let f x set =
        try
          VarSet.filter (not % p) (term_free_vars (T.V.Map.find x rewrite))
          |> VarSet.union set
        with Not_found -> VarSet.add x set
      in
      VarSet.fold f varset VarSet.empty
    in

    let rec qe rewrite vars psi =
      if VarSet.is_empty vars then
        if T.V.Map.is_empty rewrite then psi
        else subst (mk_subst rewrite) psi
      else match psi.node with
        | And xs ->

          (* Re-write /\ xs as (/\ rewrite) /\ (/\ noneqs), where rewrite is a
             set of oriented equations which eliminate existentially
             quantified variables, and noneqs is the remainder *)
          let rec split_eqs phi (eqs, noneqs) =
            match phi.node with
            | And xs -> Hset.fold split_eqs xs (eqs, noneqs)
            | Or _ -> (eqs, phi::noneqs)
            | Atom (EqZ t) -> (t::eqs, noneqs)
            | Atom _ -> (eqs, phi::noneqs)
          in
          let (eqs, noneqs) = Hset.fold split_eqs xs ([], []) in
          let f (rewrite, noneqs) term =
            let term = T.subst (mk_subst rewrite) term in
            match orient_equation (flip VarSet.mem vars) term with
            | Some (v, rhs) ->
              logf ~level:`trace "Found rewrite: %a --> %a"
                T.V.format v
                T.format rhs;

              (* Rewrite RHS of every rewrite rule to eliminate v *)
              let sub x =
                if T.V.equal x v then rhs else T.var x
              in
              let rewrite =
                T.V.Map.map (T.subst sub) rewrite
              in
              (T.V.Map.add v rhs rewrite, noneqs)
            | None ->
              logf ~level:`trace "Could not orient equation %a=0"
                T.format term;
              (rewrite, (eqz term)::noneqs)
          in
          let (rewrite, noneqs) =
            List.fold_left f (rewrite, noneqs) eqs
          in

          (* Rewrite noneqs and push in the quantifier *)
          let rec miniscope vars left = function
            | [] -> big_conj (BatList.enum left)
            | (psi::right) ->
              let scope =
                BatList.fold_left
                  (fun scope x ->
                     VarSet.diff scope (rewrite_varset rewrite (bound_vars x))
                  )
                  (VarSet.inter vars (rewrite_varset rewrite (bound_vars psi)))
                  right
              in
              let psi' = qe rewrite scope psi in
              let vars = VarSet.diff vars (bound_vars psi') in
              miniscope vars (psi'::left) right
          in
          miniscope vars [] noneqs
        | Or xs ->
          let f psi set = Hset.add (qe rewrite vars psi) set in
          hashcons (Or (Hset.fold f xs Hset.empty))
        | Atom _ ->
          let psi' = subst (mk_subst rewrite) psi in
          if VarSet.exists (flip VarSet.mem vars) (bound_vars psi') then
            (* exists x. psi is equivalent to true if phi is an atom and x
               appears in psi *)
            top
          else
            psi'
    in

    try Log.time "qe_partial" (qe T.V.Map.empty phi_bound_vars) phi
    with Is_top -> top

  let opt_qe_strategy = ref qe_lme
  let exists p phi =
    if equal phi top then top
    else if equal phi bottom then bottom
    else Log.time "Quantifier Elimination" ((!opt_qe_strategy) p) phi

  let exists_list vars phi =
    let vars = List.fold_left (flip VarSet.add) VarSet.empty vars in
    exists (not % (flip VarSet.mem vars)) phi

  module V = T.V
  module A = Linear.AffineVar(V)

  let linterm_smt =
    let num_const qq =
      match QQ.to_zz qq with
      | Some zz -> Smt.const_zz zz
      | None -> Smt.const_qq qq
    in
    T.Linterm.to_smt (A.to_smt V.to_smt) num_const

  (* Counter-example based extraction of the affine hull of a formula.  This
     works by repeatedly posing new (linearly independent) equations; each
     equation is either implied by the formula (and gets addded to the affine
     hull) or there is a counter-example point which shows that it is not.
     Counter-example points are collecting in a system of linear equations
     where the variables are the coefficients of candidate equations. *)
  let affine_hull_ceg s vars =
    let zero = Smt.const_int 0 in
    let const_var = A.to_smt V.to_smt AConst in
    let space = new Smt.solver in (* solution space for implied equalities *)
    let extract_linterm m =
      let f term v =
        T.Linterm.add_term
          (AVar v)
          (m#eval_qq (V.to_smt v))
          term
      in
      let const_term =
        T.Linterm.add_term
          AConst
          (m#eval_qq const_var)
          T.Linterm.zero
      in
      List.fold_left f const_term vars
    in
    let rec go equalities =
      match space#check () with
      | Smt.Unsat -> equalities
      | Smt.Undef -> (* give up; return the equalities we have so far *)
        Log.errorf "Affine hull timed out: %s" (space#get_reason_unknown());
        equalities
      | Smt.Sat ->
        let candidate = extract_linterm (space#get_model ()) in
        let candidate_formula =
          Smt.mk_eq (linterm_smt candidate) zero
        in
        s#push ();
        s#assrt (Smt.mk_not candidate_formula);
        match s#check () with
        | Smt.Undef -> (* give up; return the equalities we have so far *)
          Log.errorf
            "Affine hull timed out (%d equations)"
            (List.length equalities);
          equalities
        | Smt.Unsat -> (* candidate equality is implied by phi *)
          s#pop ();
          let leading =
            let e =
              let f = function
                | (AConst, _) -> None
                | (AVar x, y) -> Some (x,y)
              in
              BatEnum.filter_map f (T.Linterm.enum candidate)
            in
            match BatEnum.get e with
            | Some (dim, coeff) ->
              assert (not (QQ.equal coeff QQ.zero));
              dim
            | None -> assert false
          in
          space#assrt (Smt.mk_eq (V.to_smt leading) zero);
          go (candidate::equalities)
        | Smt.Sat -> (* candidate equality is not implied by phi *)
          let point = extract_linterm (s#get_model ()) in
          s#pop ();
          space#assrt (Smt.mk_eq (linterm_smt point) zero);
          go equalities
    in
    let nonzero v = Smt.mk_not (Smt.mk_eq (V.to_smt v) zero) in
    s#assrt (Smt.mk_eq const_var (Smt.const_int 1));
    space#assrt (Smt.big_disj (BatEnum.map nonzero (BatList.enum vars)));
    go []

  (* Affine hull as in Thomas Reps, Mooly Sagiv, and Greta Yorsh: "Symbolic
     Implementation of the Best Abstract Transformer" *)
  let affine_hull_rsy s vars =
    let open Apron in
    let open D in
    let env = Env.of_enum (BatList.enum vars) in
    let man = Polka.manager_alloc_equalities () in

    let mk_eq_prop m =
      let mk_cons v =
        Lincons0.make
          (T.apron_of_linterm env
             (T.Linterm.add_term (AVar v) QQ.one
                (T.Linterm.const (QQ.negate (m#eval_qq (T.V.to_smt v))))))
          Lincons0.EQ
      in
      let cons = BatList.map mk_cons vars in
      { prop =
          Abstract0.of_lincons_array
            man
            (Env.int_dim env)
            (Env.real_dim env)
            (Array.of_list cons);
        env = env }
    in
    let rec go prop =
      s#push ();
      s#assrt (Smt.mk_not (to_smt (of_abstract prop)));
      match s#check () with
      | Smt.Unsat ->
        s#pop ();
        prop
      | Smt.Undef ->
        begin
          Log.errorf "Affine hull timed out: %s" (s#get_reason_unknown());
          logf ~level:`trace "%s" (s#to_string());
          s#pop ();
          raise Timeout
        end
      | Smt.Sat -> begin
          let neweq = mk_eq_prop (s#get_model ()) in
          s#pop ();
          go (join prop neweq)
        end
    in
    let x = go (bottom man env) in
    let tcons = BatArray.enum (Abstract0.to_tcons_array man x.prop) in
    let to_lineq tcons =
      match T.to_linterm (T.of_apron env tcons.Tcons0.texpr0) with
      | Some lt -> lt
      | None -> assert false
    in
    BatList.of_enum (BatEnum.map to_lineq tcons)

  let affine_hull_impl s vars =
    Log.time "Affine hull" (affine_hull_ceg s) vars

  module TMap = Putil.Map.Make(T)

  let uninterpreted_nonlinear_term =
    let uninterp_mul_sym = Smt.mk_string_symbol "uninterp_mul" in
    let uninterp_div_sym = Smt.mk_string_symbol "uninterp_div" in
    let uninterp_mod_sym = Smt.mk_string_symbol "uninterp_mod" in
    let real_sort = Smt.mk_real_sort () in
    let int_sort = Smt.mk_int_sort () in
    let uninterp_mul_decl =
      Smt.mk_func_decl uninterp_mul_sym [real_sort; real_sort] real_sort
    in
    let uninterp_div_decl =
      Smt.mk_func_decl uninterp_div_sym [real_sort; real_sort] real_sort
    in
    let uninterp_mod_decl =
      Smt.mk_func_decl uninterp_mod_sym [int_sort; int_sort] int_sort
    in
    let mk_mul x y = Smt.mk_app uninterp_mul_decl [x; y] in
    let mk_div x y = Smt.mk_app uninterp_div_decl [x; y] in
    let mk_mod x y = Smt.mk_app uninterp_mod_decl [x; y] in
    let talg = function
      | OVar v -> (V.to_smt v, V.typ v)
      | OConst k ->
        begin match QQ.to_zz k with
          | Some z -> (Smt.const_zz z, TyInt)
          | None   -> (Smt.const_qq k, TyReal)
        end
      | OAdd ((x,x_typ),(y,y_typ)) -> (Smt.add x y, join_typ x_typ y_typ)
      | OMul ((x,x_typ),(y,y_typ)) -> (mk_mul x y, join_typ x_typ y_typ)
      | ODiv ((x,x_typ),(y,y_typ)) ->
        let x = match x_typ with
          | TyReal -> x
          | TyInt  -> (Smt.mk_int2real x)
        in
        let y = match y_typ with
          | TyReal -> y
          | TyInt  -> (Smt.mk_int2real y)
        in
        (mk_div x y, TyReal)
      | OMod ((x,TyInt),(y,TyInt)) -> (mk_mod x y, TyInt)
      | OMod (_, _) -> assert false
      | OFloor (x, _) -> (Smt.mk_real2int x, TyInt)
    in
    fun term -> fst (T.eval talg term)

  exception Unsat
  let nonlinear_equalities map phi vars =
    let s = new Smt.solver in
    let assert_nl_eq nl_term var =
      logf ~level:`trace "  %a = %a" V.format var T.format nl_term;
      s#assrt (Smt.mk_eq (uninterpreted_nonlinear_term nl_term) (V.to_smt var))
    in
    s#assrt (to_smt phi);
    logf ~level:`trace "Nonlinear equations:";
    TMap.iter assert_nl_eq map;
    logf ~level:`trace "done (Nonlinear equations)";
    match s#check () with
    | Smt.Sat -> affine_hull_impl s (VarSet.elements vars)
    | Smt.Undef ->
      Log.errorf "Timeout: nonlinear_equalities";
      []
    | Smt.Unsat -> raise Unsat

  (* Split a formula into a linear formula and a set of nonlinear equations by
     introducing a variable (and equation) for every nonlinear term. *)
  let split_linear mk_tmp phi =
    let nonlinear = ref TMap.empty in
    let replace_term t =
      if T.is_linear t then t else begin
        let (lin, nonlin) = T.split_linear t in
        let mk_nl_term (t, coeff) =
          let var =
            try TMap.find t (!nonlinear)
            with Not_found ->
              let v = mk_tmp () in
              nonlinear := TMap.add t v (!nonlinear);
              v
          in
          T.mul (T.var var) (T.const coeff)
        in
        BatEnum.fold T.add lin (BatList.enum nonlin /@ mk_nl_term)
      end
    in
    let alg = function
      | OOr (phi, psi) -> disj phi psi
      | OAnd (phi, psi) -> conj phi psi
      | OAtom (LeqZ t) -> leqz (replace_term t)
      | OAtom (LtZ t) -> ltz (replace_term t)
      | OAtom (EqZ t) -> eqz (replace_term t)
    in
    (eval alg phi, !nonlinear)

  (* Linearize, but avoid converting to DNF. *)
  let linearize_apron mk_tmp phi =
    let open Apron in
    let open D in
    let (lin_phi, nonlinear) = split_linear mk_tmp phi in
    let vars =
      BatEnum.fold
        (fun set (_,v) -> VarSet.add v set)
        (formula_free_vars phi)
        (TMap.enum nonlinear)
    in
    let lin_phi =
      let f phi eq =
        let g (v, coeff) =
          match v with
          | AVar v -> T.mul (T.var v) (T.const coeff)
          | AConst -> T.const coeff
        in
        conj phi (eqz (BatEnum.reduce T.add (T.Linterm.enum eq /@ g)))
      in
      let eqs = nonlinear_equalities nonlinear lin_phi vars in
      List.fold_left f lin_phi eqs
    in
    let man = Box.manager_alloc () in
    let approx = D.add_vars (VarSet.enum vars) (abstract man lin_phi) in
    let mk_nl_equation (term, var) =
      Tcons0.make (T.to_apron approx.env (T.sub term (T.var var))) Tcons0.EQ
    in
    let nl_eq =
      BatArray.of_enum (TMap.enum nonlinear /@ mk_nl_equation)
    in
    let nl_approx =
      { prop = Abstract0.meet_tcons_array man approx.prop nl_eq;
        env = approx.env }
    in
    conj lin_phi (of_abstract nl_approx)

  let linearize_apron_dnf mk_tmp phi =
    let open Apron in
    let (lin_phi, nonlinear) = split_linear mk_tmp phi in
    if TMap.is_empty nonlinear then phi else begin
      let vars =
        BatEnum.fold
          (fun set (_,v) -> VarSet.add v set)
          (formula_free_vars phi)
          (TMap.enum nonlinear)
      in
      let env = D.Env.of_enum (VarSet.enum vars) in
      logf "Linearize formula (%d dimensions, %d nonlinear)"
        (D.Env.dimension env)
        (TMap.cardinal nonlinear);
      let lin_phi =
        let f phi eq =
          let g (v, coeff) =
            match v with
            | AVar v -> T.mul (T.var v) (T.const coeff)
            | AConst -> T.const coeff
          in
          conj phi (eqz (BatEnum.reduce T.add (T.Linterm.enum eq /@ g)))
        in
        let eqs = nonlinear_equalities nonlinear lin_phi vars in
        List.fold_left f lin_phi eqs
      in
      let man = NumDomain.polka_loose_manager () in

      let join psi disjunct =
        (* todo: compute & strengthen w/ nl equalities here *)
        disjunct::psi
      in
      let to_smt = to_smt % (BatList.fold_left disj bottom) in

      let dnf = lazy_dnf ~join:join ~top:[top] ~bottom:[] to_smt lin_phi in
      let mk_nl_equation (term, var) =
        Tcons0.make (T.to_apron env (T.sub term (T.var var))) Tcons0.EQ
      in
      let nl_eq =
        BatArray.of_enum (TMap.enum nonlinear /@ mk_nl_equation)
      in
      let add_nl psi =
        let approx = to_apron man env psi in
        let open D in
        let nl_approx =
          { prop = Abstract0.meet_tcons_array man approx.prop nl_eq;
            env = approx.env }
        in
        of_abstract nl_approx
      in
      List.fold_left disj bottom (List.map add_nl dnf)
    end

  let disj_optimize terms phi =
    let man = NumDomain.polka_loose_manager () in
    let vars =
      let f vars t = VarSet.union (term_free_vars t) vars in
      List.fold_left f (formula_free_vars phi) terms
    in
    let env = D.Env.of_enum (VarSet.enum vars) in
    logf
      "Disjunctive symbolic optimization [objectives: %d, dimensions: %d]"
      (List.length terms)
      (D.Env.dimension env);
    let get_bounds prop t =
      let open D in
      let ivl =
        Log.time "bound_texpr"
          (Apron.Abstract0.bound_texpr man prop.prop) (T.to_apron prop.env t)
      in
      Interval.of_apron ivl
    in
    let join bounds disjunct =
      let prop = to_apron man env disjunct in
      let new_bounds = List.map (get_bounds prop) terms in
      new_bounds::bounds
    in
    let prop_to_smt bounds =
      let to_formula (t, ivl) =
        let lo = match Interval.lower ivl with
          | Some b -> leq (T.const b) t
          | None -> top
        in
        let hi = match Interval.upper ivl with
          | Some b -> leq t (T.const b)
          | None -> top
        in
        conj lo hi
      in
      let disjunct_smt disjunct =
        let e =
          BatEnum.combine (BatList.enum terms, BatList.enum disjunct)
        in
        to_smt (BatEnum.fold conj top (e /@ to_formula))
      in
      Smt.big_disj ((BatList.enum bounds) /@ disjunct_smt)
    in
    let top = [List.map (fun _ -> (None, None)) terms] in
    let bottom = [] in
    lazy_dnf ~join:join ~top:top ~bottom:bottom prop_to_smt phi

  (* Given a list of (linear) terms [terms] and a formula [phi], find lower
     and upper bounds for each term within the feasible region of [phi]. *)
  let optimize terms phi =
    let man = NumDomain.polka_loose_manager () in
    let term_vars =
      let f vars t = VarSet.union (term_free_vars t) vars in
      List.fold_left f VarSet.empty terms
    in
    let vars =
      let f vars t = VarSet.union (term_free_vars t) vars in
      List.fold_left f (formula_free_vars phi) terms
    in
    let env = D.Env.of_enum (VarSet.enum vars) in
    logf "Symbolic optimization [objectives: %d, dimensions: %d, size: %d]"
      (List.length terms)
      (D.Env.dimension env)
      (size phi);
    let get_bounds prop t =
      let open D in
      let ivl =
        Log.time "bound_texpr"
          (Apron.Abstract0.bound_texpr man prop.prop) (T.to_apron prop.env t)
      in
      Interval.of_apron ivl
    in
    let join bounds disjunct =
      let reduced =
        qe_partial (flip VarSet.mem term_vars) disjunct
      in

      let p = Polyhedron.of_formula reduced in

      let env =
        D.Env.of_enum
          (VarSet.enum (VarSet.union (Polyhedron.vars p) term_vars))
      in

      let prop =
        Log.time "to_apron" (Polyhedron.to_apron env man) p
      in

      let new_bounds = List.map (get_bounds prop) terms in
      BatList.map2 Interval.join bounds new_bounds
    in
    let prop_to_smt bounds =
      let to_formula (t, ivl) =
        let lo = match Interval.lower ivl with
          | Some b -> leq (T.const b) t
          | None -> top
        in
        let hi = match Interval.upper ivl with
          | Some b -> leq t (T.const b)
          | None -> top
        in
        conj lo hi
      in
      let e =
        BatEnum.combine (BatList.enum terms, BatList.enum bounds)
      in
      to_smt (BatEnum.fold conj top (e /@ to_formula))
    in
    let top = List.map (fun _ -> Interval.top) terms in
    let bottom = List.map (fun _ -> Interval.bottom) terms in
    lazy_dnf ~join:join ~top:top ~bottom:bottom prop_to_smt phi

  let optimize ts phi =
    if ts == [] then []
    else Log.time "optimize" (optimize ts) phi

  module LinBound = struct
    type t = { upper : T.t list;
               lower : T.t list;
               interval : Interval.interval }
        deriving (Compare, Show)

    let format = Show_t.format
    let show = Show_t.show
    let compare = Compare_t.compare
    let equal x y = compare x y = 0

    let cartesian f xs ys =
      let zs = ApakEnum.cartesian_product (BatList.enum xs) (BatList.enum ys) in
      BatList.of_enum (BatEnum.map (uncurry f) zs)

    let add x y =
      { upper = cartesian T.add x.upper y.lower;
        lower = cartesian T.add x.lower y.lower;
        interval = Interval.add x.interval y.interval }

    let of_interval ivl =
      { upper = [];
        lower = [];
        interval = ivl }

    let zero = of_interval Interval.zero
    let bottom = of_interval Interval.bottom
    let top = of_interval Interval.top

    let mul_interval ivl x =
      if Interval.is_nonnegative ivl then
        let upper = match Interval.upper ivl with
          | Some k -> List.map (T.mul (T.const k)) x.upper
          | None -> []
        in
        let lower = match Interval.lower ivl with
          | Some k -> List.map (T.mul (T.const k)) x.lower
          | None -> []
        in
        { upper = upper;
          lower = lower;
          interval = Interval.mul ivl x.interval }
      else if Interval.is_nonpositive ivl then
        let upper = match Interval.upper ivl with
          | Some k -> List.map (T.mul (T.const k)) x.lower
          | None -> []
        in
        let lower = match Interval.lower ivl with
          | Some k -> List.map (T.mul (T.const k)) x.upper
          | None -> []
        in
        { upper = upper;
          lower = lower;
          interval = Interval.mul ivl x.interval }
      else
        { upper = [];
          lower = [];
          interval = Interval.mul ivl x.interval }

    let meet x y =
      { upper = x.upper @ y.upper;
        lower = x.lower @ y.lower;
        interval = Interval.meet x.interval y.interval }

    let mul x y = meet (mul_interval x.interval y) (mul_interval y.interval x)

    let negate x =
      { interval = Interval.negate x.interval;
        upper = List.map T.neg x.lower;
        lower = List.map T.neg x.upper }

    let div x y =
      match Interval.lower y.interval, Interval.upper y.interval with
      | Some a, Some b ->
        if Interval.elem QQ.zero y.interval then top
        else if QQ.equal a b then begin
          if QQ.gt a QQ.zero then
            { lower = List.map (flip T.div (T.const a)) x.lower;
              upper = List.map (flip T.div (T.const a)) x.upper;
              interval = Interval.div x.interval y.interval }
          else
            { lower = List.map (flip T.div (T.const a)) x.upper;
              upper = List.map (flip T.div (T.const a)) x.lower;
              interval = Interval.div x.interval y.interval }
        end else of_interval (Interval.div x.interval y.interval) (* todo *)
      | _, _ -> of_interval (Interval.div x.interval y.interval)

    let modulo x y =
      let ivl = Interval.modulo x.interval y.interval in
      if Interval.equal ivl Interval.bottom then bottom
      else if Interval.elem QQ.zero y.interval then top
      else
        (* y is either strictly positive or strictly negative.  mod y is the
                  same as mod |y| *)
        let y =
          if Interval.is_positive y.interval then y
          else negate y
        in
        if Interval.is_nonnegative x.interval then
          { interval = ivl;
            lower = [];
            upper = x.upper@(List.map (flip T.sub T.one) (y.upper)) }
        else if Interval.is_nonpositive x.interval then
          { interval = ivl;
            lower = x.lower@(List.map (T.add T.one % T.neg) y.upper);
            upper = [] }
        else
          { interval = ivl;
            lower = List.map (T.add T.one % T.neg) y.upper;
            upper = List.map (flip T.sub T.one) y.upper }

    let make lower upper interval =
      { lower = lower; upper = upper; interval = interval }
    let lower x = x.lower
    let upper x = x.upper
    let interval x = x.interval
    let floor x = make [] [] (Interval.floor x.interval)
  end

  let linearize_opt mk_tmp phi =
    let (lin_phi, nonlinear) = split_linear mk_tmp phi in
    if TMap.is_empty nonlinear then phi else begin
      let lin_phi =
        let f phi eq =
          let g (v, coeff) =
            match v with
            | AVar v -> T.mul (T.var v) (T.const coeff)
            | AConst -> T.const coeff
          in
          conj phi (eqz (BatEnum.reduce T.add (T.Linterm.enum eq /@ g)))
        in
        (* Variables introduced to represent nonlinear terms *)
        let nl_vars =
          TMap.fold (fun _ v set -> VarSet.add v set) nonlinear VarSet.empty
        in

        let eqs = nonlinear_equalities nonlinear lin_phi nl_vars in

        logf "Extracted equalities:@ %a"
          Show.format<T.Linterm.t list> eqs;
        List.fold_left f lin_phi eqs
      in

      (* Variables which appear in nonlinear terms *)
      let var_list =
        let f t _ set = VarSet.union (term_free_vars t) set in
        VarSet.elements (TMap.fold f nonlinear VarSet.empty)
      in
      let box =
        optimize (List.map T.var var_list) lin_phi
      in
      let bounds =
        List.fold_left2
          (fun m v ivl -> T.V.Map.add v ivl m)
          T.V.Map.empty
          var_list
          box
      in
      let linearize_term = function
        | OVar v ->
          let ivl =
            try T.V.Map.find v bounds
            with Not_found -> Interval.top
          in
          LinBound.make [T.var v] [T.var v] ivl
        | OConst k -> LinBound.of_interval (Interval.const k)
        | OAdd (x, y) -> LinBound.add x y
        | OMul (x, y) -> LinBound.mul x y
        | ODiv (x, y) -> LinBound.div x y
        | OMod (x, y) -> LinBound.modulo x y
        | OFloor x -> LinBound.floor x
      in
      let mk_nl_bounds (term, var) =
        let var = T.var var in
        let linearized = T.eval linearize_term term in
        let symbolic_lo =
          big_conj (BatList.enum (LinBound.lower linearized) /@ (geq var))
        in
        let symbolic_hi =
          big_conj (BatList.enum (LinBound.upper linearized) /@ (leq var))
        in
        let const_lo = match Interval.lower (LinBound.interval linearized) with
          | Some k -> leq (T.const k) var
          | None -> top
        in
        let const_hi = match Interval.upper (LinBound.interval linearized) with
          | Some k -> leq var (T.const k)
          | None -> top
        in
        conj symbolic_lo (conj symbolic_hi (conj const_lo const_hi))
      in
      let nl_bounds = big_conj (TMap.enum nonlinear /@ mk_nl_bounds) in
      conj lin_phi nl_bounds
    end
  let linearize_trivial mk_tmp phi = fst (split_linear mk_tmp phi)
  let linearize_opt mk_tmp phi =
    try linearize_opt mk_tmp phi
    with Timeout ->
      Log.errorf "Timeout in linearize_opt; retrying with linearize_trivial";
      linearize_trivial mk_tmp phi

  let opt_linearize_strategy = ref linearize_opt

  let linearize mk_tmp phi =
    try
      Log.time "Formula linearization" (!opt_linearize_strategy mk_tmp) phi
    with Unsat -> bottom

  exception Unbounded (* Internal to qe_cover *)
  let qe_cover p phi =
    let fv = formula_free_vars phi in
    let vars = BatList.of_enum (BatEnum.filter (not % p) (VarSet.enum fv)) in
    let to_linterm t =
      match T.to_linterm t with
      | Some lt -> lt
      | None -> raise Nonlinear
    in
    let box = optimize (List.map T.var vars) phi in
    let bounds =
      List.fold_left2
        (fun m v box -> T.V.Map.add v box m)
        T.V.Map.empty
        vars
        box
    in
    let lower ivl = match Interval.lower ivl with
      | None -> raise Unbounded
      | Some x -> x
    in
    let upper ivl = match Interval.upper ivl with
      | None -> raise Unbounded
      | Some x -> x
    in
    let f (var, coeff) =
      try
        let k =
          if QQ.lt coeff QQ.zero
          then upper (T.V.Map.find var bounds)
          else lower (T.V.Map.find var bounds)
        in
        (AConst, QQ.mul coeff k)
      with Not_found -> (AVar var, coeff)
    in
    let rec replace = function
      | EqZ t -> conj (replace (LeqZ t)) (replace (LeqZ (T.neg t)))
      | LtZ t ->
        let lt = to_linterm t in
        begin try
            ltz
              (T.of_linterm
                 (T.Linterm.add
                    (T.Linterm.of_enum ((T.Linterm.var_bindings lt) /@ f))
                    (T.Linterm.const (T.Linterm.const_coeff lt))))
          with Unbounded -> top end
      | LeqZ t ->
        let lt = to_linterm t in
        begin try
            leqz
              (T.of_linterm
                 (T.Linterm.add
                    (T.Linterm.of_enum ((T.Linterm.var_bindings lt) /@ f))
                    (T.Linterm.const (T.Linterm.const_coeff lt))))
          with Unbounded -> top end
    in
    map replace phi
  let qe_cover p phi = Log.time "qe_cover" (qe_cover p) phi

  let simplify_z3 p phi =
    let open Z3 in
    let fv = formula_free_vars phi in
    let vars = BatList.of_enum (BatEnum.filter (not % p) (VarSet.enum fv)) in
    let ctx = Smt.get_context () in
    let simplify = Tactic.mk_tactic ctx "simplify" in
    let g = Goal.mk_goal ctx false false false in
    Goal.add g [Smt.mk_exists_const (List.map T.V.to_smt vars) (to_smt phi)];
    of_apply_result (Tactic.apply simplify g None)

  let opt_simplify_strategy = ref [qe_cover; simplify_dillig]
  let simplify p phi =
    Log.time "Formula simplification"
      (List.fold_left (fun phi simpl -> simpl p phi) phi)
      (!opt_simplify_strategy)

  let affine_hull ?solver:(s=new Smt.solver) phi vars =
    try
      s#push ();
      s#assrt (to_smt phi);
      let res = affine_hull_impl s vars in
      s#pop ();
      res
    with Timeout -> (s#pop (); [])

  let interpolate phi psi =
    let open Z3 in
    let fp = new Smt.fixedpoint in
    let ctx = Smt.get_context() in
    let params = Params.mk_params ctx in
    let sym = Smt.mk_string_symbol in

    Params.add_symbol params (sym ":engine") (sym "pdr");
    Params.add_bool params (sym ":pdr.farkas") true;
    Params.add_bool params (sym ":pdr.utvpi") false;
    Params.add_bool params (sym ":xform.inline_eager") false;
    Params.add_bool params (sym ":xform.inline_linear") false;
    fp#set_params params;

    let var_sort v = match V.typ v with
      | TyInt -> Smt.mk_int_sort ()
      | TyReal -> Smt.mk_real_sort ()
    in
    let common_vars =
      VarSet.elements
        (VarSet.inter (formula_free_vars phi) (formula_free_vars psi))
    in
    let mk_rel name phi =
      let sym = Smt.mk_string_symbol name in
      let fv = VarSet.elements (formula_free_vars phi) in
      let decl =
        Smt.mk_func_decl
          sym
          (BatList.map var_sort common_vars)
          (Smt.mk_bool_sort ())
      in
      let rule =
        Smt.mk_forall_const
          (List.map T.V.to_smt fv)
          (Smt.mk_implies
             (to_smt phi)
             (Smt.mk_app decl (BatList.map T.V.to_smt common_vars)))
      in
      fp#register_relation decl;
      fp#add_rule rule (Some sym);
      decl
    in
    let phi_rel = mk_rel "$A" phi in
    let query =
      let fv = List.map V.to_smt (VarSet.elements (formula_free_vars psi)) in
      Smt.mk_exists_const
        fv
        (Smt.conj
           (to_smt psi)
           (Smt.mk_app phi_rel (BatList.map T.V.to_smt common_vars)))
    in
    match fp#query query with
    | Solver.SATISFIABLE -> None
    | Solver.UNKNOWN ->
      begin
        L.errorf "Interpolation timed out";
        raise Timeout
      end
    | Solver.UNSATISFIABLE ->
      begin
        let itp = ref top in
        for i = (-1) to fp#get_num_levels phi_rel do
          let delta = match fp#get_cover_delta i phi_rel with
            | Some d -> d
            | None -> assert false
          in
          itp := conj (!itp) (of_smt ~bound_vars:common_vars delta)
        done;
        Some (!itp)
      end
  let interpolate phi psi =
    if is_sat phi then interpolate phi psi
    else Some bottom

  let nudge_atom acc = function
    | LeqZ t -> leqz (T.nudge_down ~accuracy:acc t)
    | LtZ t -> ltz (T.nudge_down ~accuracy:acc t)
    | EqZ t ->
      let (lo,hi) = T.nudge ~accuracy:acc t in
      conj (leqz lo) (leqz (T.neg hi))

  let nudge ?(accuracy=(!opt_default_accuracy)) phi =
    map (nudge_atom accuracy) phi

  let boxify templates phi =
    let bounds = optimize templates phi in
    let to_formula template ivl =
      let lower = match Interval.lower ivl with
        | Some lo -> leq (T.const lo) template
        | None -> top
      in
      let upper = match Interval.upper ivl with
        | Some hi -> leq template (T.const hi)
        | None -> top
      in
      conj lower upper
    in
    big_conj (BatList.enum (List.map2 to_formula templates bounds))

  let simplify_dillig_nonlinear mk_tmp _ phi =
    (* Replace nonlinear terms with fresh vars & create map between the fresh
       vars and the nonlinear terms they represent *)
    let (lin_phi, nonlinear) = split_linear mk_tmp phi in
    let s = new Smt.solver in
    (* Add uninterp equality to the context for each fresh var *)
    let assert_nl_eq nl_term var =
      s#assrt (Smt.mk_eq (uninterpreted_nonlinear_term nl_term) (V.to_smt var))
    in
    TMap.iter assert_nl_eq nonlinear;
    s#push ();
    (* reverse map sends each variable to the nonlinear term it represents *)
    let rev =
      TMap.fold (fun t v rev -> VarMap.add v t rev) nonlinear VarMap.empty
    in
    (* substitution re-introduces non-linear terms *)
    let sigma v =
      try VarMap.find v rev
      with Not_found -> T.var v
    in
    subst sigma (simplify_dillig_impl lin_phi s)

  let rec format_robust formatter phi =
    let open Format in
    let sort =
      BatList.sort
        (fun x y -> Pervasives.compare (nb_atoms x) (nb_atoms y))
    in
    match phi.node with
    | Or xs ->
      fprintf formatter "(@[<v 0>";
      ApakEnum.pp_print_enum_nobox
        ~pp_sep:(fun formatter () -> fprintf formatter "@;|| ")
        format_robust
        formatter
        (BatList.enum (sort (Hset.elements xs)));
      fprintf formatter "@])"
    | And xs ->
      fprintf formatter "(@[<v 0>";
      ApakEnum.pp_print_enum_nobox
        ~pp_sep:(fun formatter () -> fprintf formatter "@;&& ")
        format_robust
        formatter
        (BatList.enum (sort (Hset.elements xs)));
      fprintf formatter "@])"
    | Atom (LeqZ t) -> fprintf formatter "@[%a <= 0@]" T.format t
    | Atom (EqZ t) -> fprintf formatter "@[%a == 0@]" T.format t
    | Atom (LtZ t) -> fprintf formatter "@[%a < 0@]" T.format t

  let opt_abstract_limit = ref (-1)

  (* Same as abstract, except local polyhedral projection is used instead of
     projection in Apron's abstract domain. *)
  let local_abstract ?exists:(p=None) s man phi =
    let open D in
    let env = mk_env phi in
    let env_proj = match p with
      | Some p -> D.Env.filter p env
      | None   -> env
    in
    let projected_vars =
      match p with
      | Some p -> VarSet.of_enum (BatEnum.filter (not % p) (D.Env.vars env))
      | None -> VarSet.empty
    in
    let disjuncts = ref 0 in
    let rec go prop =
      s#push ();
      s#assrt (Smt.mk_not (to_smt (of_abstract prop)));
      match Log.time "lazy_dnf/sat" s#check () with
      | Smt.Unsat ->
        s#pop ();
        prop
      | Smt.Undef ->
        begin
          Log.errorf "lazy_dnf timed out (%d disjuncts)" (!disjuncts);
          s#pop ();
          raise Timeout
        end
      | Smt.Sat -> begin
          let m = s#get_model () in
          let valuation = m#eval_qq % T.V.to_smt in
          s#pop ();
          incr disjuncts;
          logf "[%d] abstract lazy_dnf" (!disjuncts);
          if (!disjuncts) = (!opt_abstract_limit) then begin
            Log.errorf "Met symbolic abstraction limit; returning top";
            D.top man env_proj
          end else begin
            let disjunct =
              match
                Log.time "Poly.select" (Polyhedron.select valuation) phi
              with
              | Some d -> d
              | None -> begin
                  assert (m#sat (to_smt phi));
                  assert false
                end
            in
            let projected_disjunct =
              Polyhedron.local_project valuation projected_vars disjunct
              |> Polyhedron.to_apron env_proj man
            in
            go (D.join prop projected_disjunct)
          end
        end
    in
    try
      Log.time "Abstraction" go (D.bottom man env_proj)
    with Timeout -> begin
        Log.errorf "Symbolic abstraction timed out; returning top";
        D.top man env_proj
      end
       | Not_found -> assert false

  let abstract ?exists:(p=None) ?solver:(s=new Smt.solver) man phi =
    s#push ();
    s#assrt (to_smt phi);
    let res = local_abstract ~exists:p s man phi in
    s#pop ();
    res

  module Syntax = struct
    let ( && ) x y = conj x y
    let ( || ) x y = disj x y
    let ( == ) x y = eq x y
    let ( < ) x y = lt x y
    let ( > ) x y = gt x y
    let ( <= ) x y = leq x y
    let ( >= ) x y = geq x y
  end

  module VPMap = BatMap.Make(struct
      type t = T.V.t * T.V.t deriving (Compare, Show)
      let compare = Compare_t.compare
    end)

  let rec distinct_pairs enum =
    match BatEnum.get enum with
    | None -> BatEnum.empty ()
    | Some first ->
      let rest = distinct_pairs (BatEnum.clone enum) in
      BatEnum.append (enum /@ (fun x -> (first, x))) rest

  let var_bounds fresh vars tick_var man phi =
    let s = new Smt.solver in
    let phi = nudge ~accuracy:1 phi in
    let zero = fresh "0" TyInt in
    s#assrt (to_smt phi);
    s#assrt (to_smt (eqz (T.var zero)));

    (* Synthetic dimensions for intervals *)
    let intervals =
      distinct_pairs (BatList.enum (zero::vars))
      |> BatEnum.fold (fun map (x, y) ->
          let x_to_y =
            fresh ("[" ^ (T.V.show x) ^ "," ^ (T.V.show y) ^ "]") TyReal
          in
          VPMap.add (x, y) x_to_y map)
        VPMap.empty
    in

    (* Environment with all free variables in phi *)
    let env_phi =
      VarSet.union
        (VarSet.of_enum (BatList.enum (tick_var::vars)))
        (formula_free_vars phi)
      |> VarSet.enum
      |> D.Env.of_enum
    in
    (* Projected environment *)
    let env_proj = D.Env.of_list (tick_var::vars) in
    (* Projected environment + synthetic dimensions *)
    let env_synth =
      VarSet.union
        (VarSet.of_enum (VPMap.values intervals))
        (VarSet.of_enum (BatList.enum (zero::tick_var::vars)))
      |> VarSet.enum
      |> D.Env.of_enum
    in
    let keep_vars = VarSet.of_enum (BatList.enum (tick_var::vars)) in
    let projected_vars =
      BatEnum.filter
        (fun x -> not (VarSet.mem x keep_vars))
        (D.Env.vars env_phi)
      |> VarSet.of_enum
    in
    let disjuncts = ref 0 in
    let rec go (vars, prop, prop_synth) =
      s#push ();
      s#assrt (Smt.mk_not (to_smt (of_abstract prop)));
      match Log.time "lazy_dnf/sat" s#check () with
      | Smt.Unsat ->
        s#pop ();
        prop_synth
      | Smt.Undef ->
        begin
          Log.errorf "lazy_dnf timed out (%d disjuncts): %s"
            (!disjuncts)
            (s#get_reason_unknown());
          s#pop ();
          raise Timeout
        end
      | Smt.Sat -> begin
          let m = s#get_model () in
          let valuation = m#eval_qq % T.V.to_smt in
          s#pop ();
          incr disjuncts;
          if (!disjuncts) = (!opt_abstract_limit) then begin
            Log.errorf "Met symbolic abstraction limit; returning top";
            D.top man env_synth
          end else begin
            let disjunct =
              match
                Log.time "Poly.select" (Polyhedron.select valuation) phi
              with
              | Some d -> d |> Polyhedron.simplify_minimal
              | None -> assert false
            in
            let projected_disjunct =
              Polyhedron.conjoin
                (Polyhedron.of_atom (EqZ (T.var zero)))
                (Polyhedron.local_project valuation projected_vars disjunct)
            in
            let dims =
              VarSet.union
                vars
                (Polyhedron.dimensions projected_disjunct)
            in
            let projected_disjunct =
              projected_disjunct |> Polyhedron.to_apron env_synth man
            in
            let add_interval (x,y) x_to_y prop =
              let open D in
              let open Apron in
              if (VarSet.mem x dims && VarSet.mem y dims) then begin
                let x_to_y_cmp_0 = (* [x,y] *)
                  T.apron_of_linterm env_synth
                    (T.Linterm.add_term (AVar x_to_y) QQ.one
                       (T.Linterm.const QQ.zero))
                in
                let x_to_y_cmp_diff = (* [x,y] - (y - x) *)
                  T.apron_of_linterm env_synth
                    (T.Linterm.of_enum (BatList.enum [
                         (AVar x_to_y, QQ.one);
                         (AVar x, QQ.one);
                         (AVar y, QQ.negate QQ.one)
                       ]))
                in
                (* prop /\ [x,y] >= y - x /\ [x,y] >= 0*)
                let prop_ub =
                  Abstract0.meet_lincons_array man prop.prop
                    [| Lincons0.make x_to_y_cmp_diff Lincons0.SUPEQ;
                       Lincons0.make x_to_y_cmp_0 Lincons0.SUPEQ |]
                in
                (* prop_ub /\ [x,y] = 0 *)
                let prop_0 =
                  Abstract0.meet_lincons_array man prop_ub
                    [| Lincons0.make x_to_y_cmp_0 Lincons0.EQ |]
                in
                (* prop_ub /\ [x,y] = y - x *)
                let prop_diff =
                  Abstract0.meet_lincons_array man prop_ub
                    [| Lincons0.make x_to_y_cmp_diff Lincons0.EQ |]
                in
                { prop = Abstract0.join man prop_0 prop_diff;
                  env = prop.env }
              end else
                let x_to_y_geq_0 =
                  Lincons0.make
                    (T.apron_of_linterm env_synth
                       (T.Linterm.add_term (AVar x_to_y) QQ.one
                          (T.Linterm.const QQ.zero)))
                    Lincons0.SUPEQ
                in
                { prop =
                    (Abstract0.meet_lincons_array man prop.prop
                       [| x_to_y_geq_0 |]);
                  env = prop.env}
            in
            let disjunct_with_defs =
              VPMap.fold add_interval intervals projected_disjunct
            in
            let prop_synth =
              VPMap.fold add_interval intervals prop_synth
            in
            go (dims,
                D.join prop projected_disjunct,
                D.join prop_synth disjunct_with_defs)
          end
        end
    in
    try
      Log.time "Abstraction" go (VarSet.empty, D.bottom man env_proj, D.bottom man env_synth)
    with Timeout -> begin
        Log.errorf "Symbolic abstraction timed out; returning top";
        D.top man env_synth
      end
end
