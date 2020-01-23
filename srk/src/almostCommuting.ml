open Linear

module VS = QQVectorSpace

type kind = Commute | Reset | Ignore

type phased_segment = {
  sim1 : QQMatrix.t;
  sim2 : QQMatrix.t;
  phase1 : QQMatrix.t array;
  phase2 : (kind * QQMatrix.t) array
}

type phased_segmentation = phased_segment list

let commuting_space mA mB =
  let dims = SrkUtil.Int.Set.elements (QQMatrix.row_set mA) in
  let mAB = QQMatrix.mul mA mB in
  let mBA = QQMatrix.mul mB mA in
  let mC = QQMatrix.add mAB (QQMatrix.scalar_mul (QQ.negate QQ.one) mBA) in
  nullspace (QQMatrix.transpose mC) dims

let intersect_rowspaces matrices dims =
  Array.fold_left 
    (fun mA mB -> 
      let (mC, _) = intersect_rowspace mA mB in
      QQMatrix.mul mC mA)
    (QQMatrix.identity dims)
    matrices

let rowspace_equal mA mB =
  VS.equal (VS.of_matrix mA) (VS.of_matrix mB)

let commuting_segment matrices dims =
  let pairs = BatArray.cartesian_product matrices matrices in
  let cspaces = Array.map (fun (mA, mB) -> VS.matrix_of (commuting_space mA mB)) pairs in
  let mS = intersect_rowspaces cspaces dims in
  let rec fix mS =
    let maxlds = Array.map (fun mat -> max_lds mS (QQMatrix.mul mS mat)) matrices in
    let sims, matr = BatArray.split maxlds in
    let mSS = intersect_rowspaces 
                (Array.map (fun m -> QQMatrix.mul m mS) sims)
                dims
    in
    if rowspace_equal mS mSS then
      mS, matr
    else
      fix mSS
  in
  fix mS

let iter_all     = Array.map (fun (_, m) -> m)
let iter_reset   = BatArray.filter_map (fun (k, m) -> if k == Reset then Some m else None)
let iter_commute = BatArray.filter_map (fun (k, m) -> if k == Commute then Some m else None)

module PhasedSegment = struct

  type t = phased_segment

  (* TODO: find proper representation *)
  let show p = QQMatrix.show p.sim1

  let equal p q =
    QQMatrix.equal p.sim1 q.sim1 &&
    QQMatrix.equal p.sim2 q.sim2 &&
    BatArray.for_all2
      QQMatrix.equal
      p.phase1
      q.phase1 &&
    BatArray.for_all2
      (fun (k1, m1) (k2, m2) -> k1 == k2 && QQMatrix.equal m1 m2)
      p.phase2
      q.phase2

  let subspace p q = VS.subspace (VS.of_matrix p.sim2) (VS.of_matrix q.sim2)

  let dimension p = VS.dimension (VS.of_matrix p.sim2)

  let make pairs =
    if Array.length pairs == 0 then
      raise (Invalid_argument "Array of matrices should not be empty")
    else
      let _, mA = Array.get pairs 0 in
      let dims = SrkUtil.Int.Set.elements (QQMatrix.column_set mA) in
      let mS, phase1 = commuting_segment (iter_all pairs) dims in
      let mT, _ = commuting_segment (iter_commute pairs) dims in
      let maxldss mT =
        Array.map
          (fun (k, m) ->
            if k == Reset then
              max_lds ~zero_rows:true mS (QQMatrix.mul mT m)
            else if k == Commute then
              max_lds mT (QQMatrix.mul mT m)
            else
              mT, m)
          pairs
      in
      let ls = maxldss mT in
      let mk_sim2 mT ls = intersect_rowspaces
                            (Array.map (fun (m, _) -> QQMatrix.mul m mT) ls)
                            dims
      in
      let mT' = mk_sim2 mT ls in
      let ls' = if rowspace_equal mT mT' then ls else maxldss mT' in
      let phase2 = Array.map2 (fun (k, _) (_, m) -> (k, m)) pairs ls' in
      (* Abstraction fixpoint should be reached after at most two steps *)
      assert (rowspace_equal mT' (mk_sim2 mT' ls'));
      { sim1 = mS;
        sim2 = mT';
        phase1 = phase1;
        phase2 = phase2 }

end

let set_kind ps i k =
  let ps' = Array.copy ps in
  let _, mM = Array.get ps' i in
  Array.set ps' i (k, mM);
  ps'

let fold_ignore start pairs fn =
  let rec iter prev pairs i fn =
    if i < Array.length pairs then
      let k, mM = Array.get pairs i in
      if k == Ignore then
        let halt, res = fn prev pairs i in
        if halt then
          true, res
        else
          iter res pairs (i+1) fn
      else
        iter prev pairs (i+1) fn
    else
      false, prev
  in
  iter start pairs 0 fn

let iter_ignore pairs fn =
  let rec iter pairs i fn =
    if i < Array.length pairs then
      let k, mM = Array.get pairs i in
      if k == Ignore then
        let halt, res = fn pairs i in
        if halt then
          true, res
        else
          iter pairs (i+1) fn
      else
        iter pairs (i+1) fn
    else
      false, None
  in
  iter pairs 0 fn

type state = Close | Cancel | Refine

let next_reset pairs dim =
  let check_subsumption prev ps i =
    let rpairs = set_kind pairs i Reset in
    let rseg = PhasedSegment.make rpairs in
    let cpairs = set_kind pairs i Commute in
    let check_cext prev ps' i' =
      let cpairs' = set_kind pairs i Commute in
      let cseg = PhasedSegment.make cpairs' in
      if not (PhasedSegment.subspace rseg cseg) then
        if (PhasedSegment.dimension rseg) < dim then
          true, (Refine, Some rpairs)
        else
          false, prev
      else
        false, (Cancel, None)
    in
    fold_ignore prev cpairs check_cext
  in
  let _, result = fold_ignore (Close, None) pairs check_subsumption in
  result

module PhasedSegmentation = struct

  type t = phased_segment list

  let make_naive matrices = 
    let len = Array.length matrices in
    let products = BatList.n_cartesian_product (BatList.make len [Commute; Reset]) in
    let partitions = BatList.map 
                       (fun p -> Array.map2 (fun x y -> x, y) (Array.of_list p) matrices) 
                       products
    in
    BatList.map PhasedSegment.make partitions

  let almost_commuting_space segmentation =
    List.fold_left
      (fun vU s -> VS.sum vU (VS.of_matrix s.sim2))
      VS.empty
      segmentation

  let almost_commutes segmentation =
    let vU = almost_commuting_space segmentation in
    let dim = VS.dimension vU in
    VS.equal vU (VS.standard_basis dim)

  let best_almost_commuting matrices =
    let segmentation = make_naive matrices in
    let mC = VS.matrix_of (almost_commuting_space segmentation) in
    mC, (Array.map (fun m -> 
                      match divide_right (QQMatrix.mul mC m) mC with
                      | Some mM -> mM
                      | None -> assert false)
                   matrices)

end