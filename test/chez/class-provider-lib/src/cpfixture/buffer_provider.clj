(ns cpfixture.buffer-provider
  (:require [cpfixture.state :as state]))

(state/note-load! :buffer)

;; A class-name string extends a known built-in class.  This is intentionally a
;; member ByteBuffer does not have in core, so the first call exercises the
;; provider miss/load/one-retry path rather than a constructor/static shortcut.
(__register-class-methods!
 "java.nio.ByteBuffer"
 {"providerMarker" (fn [self] [:provider (.position self)])})
