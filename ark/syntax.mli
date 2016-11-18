(** Syntactic manipulation of terms and formulas. *)

(** A context manages symbols and sharing between expressions. [context] is a
    phantom type: the ['a] type parameter ensures that expressions don't cross
    contexts. *)
type 'a context

(** Environments are maps whose domain is a set of free variable symbols.
    Typically used to travese quantified formulas. *)
module Env : sig
  type 'a t
  val empty : 'a t
  val push : 'a -> 'a t -> 'a t
  val find : 'a t -> int -> 'a
end

(** {2 Types} *)
type typ_arith = [ `TyInt | `TyReal ]
type typ_fo = [ `TyInt | `TyReal | `TyBool ]
type typ = [ `TyInt | `TyReal | `TyBool | `TyFun of (typ_fo list) * typ_fo]
type typ_bool = [ `TyBool ]
type 'a typ_fun = [ `TyFun of (typ_fo list) * 'a ]

val pp_typ : Format.formatter -> [< typ] -> unit

(** {2 Symbols} *)

(** Symbols are represented as non-negative integers, but the type definition
    is hidden.  The isomorphism is witnessed by [int_of_symbol] and
    [symbol_of_int]. *)
type symbol

val mk_symbol : 'a context -> ?name:string -> typ -> symbol

val pp_symbol : 'a context -> Format.formatter -> symbol -> unit

val typ_symbol : 'a context -> symbol -> typ

val show_symbol : 'a context -> symbol -> string

val int_of_symbol : symbol -> int

val symbol_of_int : int -> symbol

val compare_symbol : symbol -> symbol -> int

module Symbol : sig
  type t = symbol
  val compare : t -> t -> int
  module Set : BatSet.S with type elt = symbol
  module Map : BatMap.S with type key = symbol
end

(** {2 Expressions} *)

type ('a, +'typ) expr
type 'a term = ('a, typ_arith) expr
type 'a formula = ('a, typ_bool) expr

val refine : 'a context -> ('a, typ_fo) expr -> [ `Term of 'a term
                                                | `Formula of 'a formula ]

val size : ('a, 'typ_fo) expr -> int

val mk_const : 'a context -> symbol -> ('a, 'typ) expr

val mk_app : 'a context -> symbol -> ('a, 'b) expr list -> ('a, 'typ) expr

val mk_var : 'a context -> int -> typ_fo -> ('a, 'typ) expr

val mk_ite : 'a context -> 'a formula -> ('a, 'typ) expr -> ('a, 'typ) expr ->
  ('a, 'typ) expr

val mk_iff : 'a context -> 'a formula -> 'a formula -> 'a formula

val substitute : 'a context ->
  (int -> ('a,'b) expr) -> ('a,'typ) expr -> ('a,'typ) expr

val substitute_const : 'a context ->
  (symbol -> ('a,'b) expr) -> ('a,'typ) expr -> ('a,'typ) expr

val fold_constants : (symbol -> 'a -> 'a) -> ('b, 'c) expr -> 'a -> 'a

(** {3 Expression rewriting} *)

(** A rewriter is a function that transforms an expression into another.  {b
    The transformation should preserve types}; if not, [rewrite] will fail. *)
type 'a rewriter = ('a, typ_fo) expr -> ('a, typ_fo) expr

(** Rewrite an expression.  The {i down} rewriter is applied to each
    expression going down the expression tree, and the {i up} rewriter is
    applied to each expression going up the tree. *)
val rewrite : 'a context -> ?down:('a rewriter) -> ?up:('a rewriter) ->
  ('a, 'typ) expr -> ('a, 'typ) expr

(** Convert to negation normal form ({i down} pass). *)
val nnf_rewriter : 'a context -> 'a rewriter

module ExprHT : sig
  type ('a, 'typ, 'b) t
  val create : int -> ('a, 'typ, 'b) t
  val add : ('a, 'typ, 'b) t -> ('a, 'typ) expr -> 'b -> unit
  val replace : ('a, 'typ, 'b) t -> ('a, 'typ) expr -> 'b -> unit
  val remove : ('a, 'typ, 'b) t -> ('a, 'typ) expr -> unit
  val find : ('a, 'typ, 'b) t -> ('a, 'typ) expr -> 'b
  val mem : ('a, 'typ, 'b) t -> ('a, 'typ) expr -> bool
  val keys : ('a, 'typ, 'b) t -> (('a, 'typ) expr) BatEnum.t
  val values : ('a, 'typ, 'b) t -> 'b BatEnum.t
  val enum : ('a, 'typ, 'b) t -> (('a, 'typ) expr * 'b) BatEnum.t
end

(** {2 Terms} *)

type ('a,'b) open_term = [
  | `Real of QQ.t
  | `Const of symbol
  | `App of symbol * (('b, typ_fo) expr list)
  | `Var of int * typ_arith
  | `Add of 'a list
  | `Mul of 'a list
  | `Binop of [ `Div | `Mod ] * 'a * 'a
  | `Unop of [ `Floor | `Neg ] * 'a
  | `Ite of ('b formula) * 'a * 'a
]

val mk_add : 'a context -> 'a term list -> 'a term
val mk_mul : 'a context -> 'a term list -> 'a term
val mk_div : 'a context -> 'a term -> 'a term -> 'a term
val mk_mod : 'a context -> 'a term -> 'a term -> 'a term
val mk_real : 'a context -> QQ.t -> 'a term
val mk_floor : 'a context -> 'a term -> 'a term
val mk_neg : 'a context -> 'a term -> 'a term
val mk_sub : 'a context -> 'a term -> 'a term -> 'a term

val term_typ : 'a context -> 'a term -> typ_arith

module Term : sig
  type 'a t = 'a term
  val equal : 'a term -> 'a term -> bool
  val compare : 'a term -> 'a term -> int
  val hash : 'a term -> int
  val pp : ?env:(string Env.t) -> 'a context ->
    Format.formatter -> 'a term -> unit
  val show : ?env:(string Env.t) -> 'a context -> 'a term -> string
  val destruct : 'a context -> 'a term -> ('a term, 'a) open_term
  val eval : 'a context -> (('b, 'a) open_term -> 'b) -> 'a term -> 'b
end

(** {2 Formulas} *)

type ('a,'b) open_formula = [
  | `Tru
  | `Fls
  | `And of 'a list
  | `Or of 'a list
  | `Not of 'a
  | `Quantify of [`Exists | `Forall] * string * typ_fo * 'a
  | `Atom of [`Eq | `Leq | `Lt] * ('b term) * ('b term)
  | `Proposition of [ `Const of symbol
                    | `Var of int
                    | `App of symbol * (('b, typ_fo) expr) list ]
  | `Ite of 'a * 'a * 'a
]

val mk_forall : 'a context -> ?name:string -> typ_fo -> 'a formula -> 'a formula
val mk_exists : 'a context -> ?name:string -> typ_fo -> 'a formula -> 'a formula
val mk_forall_const : 'a context -> symbol -> 'a formula -> 'a formula
val mk_exists_const : 'a context -> symbol -> 'a formula -> 'a formula

val mk_and : 'a context -> 'a formula list -> 'a formula
val mk_or : 'a context -> 'a formula list -> 'a formula
val mk_not : 'a context -> 'a formula -> 'a formula
val mk_eq : 'a context -> 'a term -> 'a term -> 'a formula
val mk_lt : 'a context -> 'a term -> 'a term -> 'a formula
val mk_leq : 'a context -> 'a term -> 'a term -> 'a formula
val mk_true : 'a context -> 'a formula
val mk_false : 'a context -> 'a formula

val eliminate_ite : 'a context -> 'a formula -> 'a formula

module Formula : sig
  type 'a t = 'a formula
  val equal : 'a formula -> 'a formula -> bool
  val compare : 'a formula -> 'a formula -> int
  val hash : 'a formula -> int
  val pp : ?env:(string Env.t) -> 'a context ->
    Format.formatter -> 'a formula -> unit
  val show : ?env:(string Env.t) -> 'a context -> 'a formula -> string
  val destruct : 'a context -> 'a formula -> ('a formula, 'a) open_formula
  val eval : 'a context -> (('b, 'a) open_formula -> 'b) -> 'a formula -> 'b
  val existential_closure : 'a context -> 'a formula -> 'a formula
  val skolemize_free : 'a context -> 'a formula -> 'a formula
  val prenex : 'a context -> 'a formula -> 'a formula
end

(** {2 Satisfiability modulo theories} *)

class type ['a] smt_model = object
  method eval_int : 'a term -> ZZ.t
  method eval_real : 'a term -> QQ.t
  method sat :  'a formula -> bool
  method to_string : unit -> string
end

class type ['a] smt_solver = object
  method add : ('a formula) list -> unit
  method push : unit -> unit
  method pop : int -> unit
  method reset : unit -> unit
  method check : ('a formula) list -> [ `Sat | `Unsat | `Unknown ]
  method to_string : unit -> string
  method get_model : unit -> [ `Sat of 'a smt_model | `Unsat | `Unknown ]
  method get_unsat_core : ('a formula) list ->
    [ `Sat | `Unsat of ('a formula) list | `Unknown ]
end

(** {2 Contexts} *)

module type Context = sig
  type t (* magic type parameter unique to this context *)
  val context : t context
  type term = (t, typ_arith) expr
  type formula = (t, typ_bool) expr

  val mk_symbol : ?name:string -> typ -> symbol
  val mk_const : symbol -> (t, 'typ) expr
  val mk_app : symbol -> (t, 'b) expr list -> (t, 'typ) expr
  val mk_var : int -> typ_fo -> (t, 'typ) expr
  val mk_add : term list -> term
  val mk_mul : term list -> term
  val mk_div : term -> term -> term
  val mk_mod : term -> term -> term
  val mk_real : QQ.t -> term
  val mk_floor : term -> term
  val mk_neg : term -> term
  val mk_sub : term -> term -> term
  val mk_forall : ?name:string -> typ_fo -> formula -> formula
  val mk_exists : ?name:string -> typ_fo -> formula -> formula
  val mk_forall_const : symbol -> formula -> formula
  val mk_exists_const : symbol -> formula -> formula
  val mk_and : formula list -> formula
  val mk_or : formula list -> formula
  val mk_not : formula -> formula
  val mk_eq : term -> term -> formula
  val mk_lt : term -> term -> formula
  val mk_leq : term -> term -> formula
  val mk_true : formula
  val mk_false : formula
  val mk_ite : formula -> (t, 'a) expr -> (t, 'a) expr -> (t, 'a) expr
end

module MakeContext () : Context

(** Create a context which simplifies expressions on the fly *)
module MakeSimplifyingContext () : Context

module Infix (C : sig
    type t
    val context : t context
  end) : sig
  val exists : ?name:string -> typ_fo -> C.t formula -> C.t formula
  val forall : ?name:string -> typ_fo -> C.t formula -> C.t formula
  val ( ! ) : C.t formula -> C.t formula
  val ( && ) : C.t formula -> C.t formula -> C.t formula
  val ( || ) : C.t formula -> C.t formula -> C.t formula
  val ( < ) : C.t term -> C.t term -> C.t formula
  val ( <= ) : C.t term -> C.t term -> C.t formula
  val ( = ) : C.t term -> C.t term -> C.t formula
  val tru : C.t formula
  val fls : C.t formula

  val ( + ) : C.t term -> C.t term -> C.t term
  val ( - ) : C.t term -> C.t term -> C.t term
  val ( * ) : C.t term -> C.t term -> C.t term
  val ( / ) : C.t term -> C.t term -> C.t term
  val ( mod ) : C.t term -> C.t term -> C.t term
  val const : symbol -> (C.t, 'typ) expr
  val var : int -> typ_fo -> (C.t, 'typ) expr
end