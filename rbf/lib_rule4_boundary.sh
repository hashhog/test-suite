# lib_rule4_boundary.sh — verdict for the exact-boundary Rule-4 replacement.
#
# rule4ok_verdict <core_ok> <core_reason> <ouro_ok> <ouro_reason>
#   prints one line; exit 0 = ok, 1 = FAIL (ouroboros diverged), 2 = INCONCLUSIVE.
# The Core oracle is the control: if Core itself does not accept the replacement
# the probe says nothing about ouroboros, so it is never reported as an
# ouroboros FAIL (2026-11-04: core=false 'replacement-failed' was blamed on a
# node that had accepted).
rule4ok_verdict() {
    local co="$1" cr="$2" io="$3" ir="$4"
    if [[ "$co" != "true" ]]; then
        echo "INCONCLUSIVE: Core oracle control rejected the exact-boundary replacement (reason='$cr'); ouroboros answered ${io} ('$ir') -- control broken, no verdict on ouroboros"
        return 2
    fi
    if [[ "$io" != "true" ]]; then
        echo "FAIL: ouroboros rejected the exact-boundary replacement that Core accepts (reason='$ir')"
        return 1
    fi
    echo "ok"
    return 0
}
