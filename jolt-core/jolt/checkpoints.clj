(ns jolt.checkpoints
  "Compiler-owned deterministic checkpoint declarations.

  `checkpoint!` is source syntax only.  The analyzer turns its private expansion
  into a :checkpoint-decl IR leaf; `lower` then erases that leaf in the default
  :plain profile or retains a controlled-only :checkpoint leaf.  No runtime
  controller is installed by this namespace."
  (:require [jolt.ir :as ir]))

(def dispositions
  "The complete disposition vocabulary understood by the compiler ABI."
  #{:continue :yield :barrier :fault :cancel})

(def profiles #{:plain :controlled})

(defmacro checkpoint!
  "Declare a deterministic checkpoint with a literal qualified keyword ID and
  a literal disposition set.  `:continue` is mandatory; the analyzer validates
  the complete declaration before producing IR."
  [id disposition-set]
  `(jolt.checkpoints/__checkpoint ~id ~disposition-set))

(defn configure-unit!
  "Select the checkpoint lowering profile for one compilation unit.  Production
  units default to :plain; :controlled is currently a compiler/test seam only."
  [unit profile]
  (when-not (contains? profiles profile)
    (throw (ex-info "invalid Jolt checkpoint profile"
                    {:profile profile :expected (vec (sort profiles))})))
  (let [cell (get unit :checkpoint-profile)
        frozen-cell (get unit :checkpoint-profile-frozen?)]
    (when-not (and cell frozen-cell)
      (throw (ex-info "Jolt compilation unit has no checkpoint profile"
                      {:profile profile})))
    (when (and @frozen-cell (not= @cell profile))
      (throw (ex-info "Jolt checkpoint profile is frozen for this compilation unit"
                      {:profile @cell :requested profile})))
    (reset! cell profile))
  nil)

(defn unit-profile [unit]
  (if-let [cell (get unit :checkpoint-profile)] @cell :plain))

(declare lower)

(defn- lower-node [profile node]
  (cond
    (or (= :checkpoint-decl (get node :op))
        (= :checkpoint (get node :op)))
    (if (= profile :controlled)
      (assoc node :op :checkpoint)
      (cond-> (ir/const nil)
        (get node :pos) (assoc :pos (get node :pos))))

    ;; Removing a statement-position declaration should not leave a synthetic
    ;; `(begin nil value)` in production output.  Only checkpoint declarations
    ;; are removed; an explicit user-written nil statement is preserved.
    (= :do (get node :op))
    (let [statements (mapv #(lower-node profile %)
                           (if (= profile :plain)
                             (remove #(contains? #{:checkpoint-decl :checkpoint}
                                                 (get % :op))
                                     (get node :statements))
                             (get node :statements)))
          ret (lower-node profile (get node :ret))]
      (if (empty? statements)
        ret
        (assoc node :statements statements :ret ret)))

    :else (ir/map-ir-children #(lower-node profile %) node)))

(defn lower
  "Consume every :checkpoint-decl in node according to unit's explicit profile.
  The pass is total and idempotent over already-lowered IR."
  [unit node]
  (let [profile (unit-profile unit)]
    (when-not (contains? profiles profile)
      (throw (ex-info "invalid Jolt checkpoint profile in compilation unit"
                      {:profile profile})))
    (when-let [frozen-cell (get unit :checkpoint-profile-frozen?)]
      (reset! frozen-cell true))
    (lower-node profile node)))
