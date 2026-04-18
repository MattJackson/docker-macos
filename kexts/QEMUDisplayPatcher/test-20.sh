#!/bin/bash
# 20-boot consistency test for QEMUDisplayPatcher
# Waits for ACTUAL new boot to reach login screen before checking results

PASS=0
FAIL=0

for boot in $(seq 1 20); do
    # Count loginwindow occurrences BEFORE this boot
    BEFORE=$(ssh docker "sudo docker logs macos-macos-1 2>&1 | grep -c 'loginwindow'" 2>/dev/null)

    # Start VM
    ssh docker "sudo docker start macos-macos-1" 2>/dev/null

    # Wait for loginwindow count to INCREASE (new boot reached login)
    echo -n "Boot $boot: waiting..."
    while true; do
        sleep 10
        AFTER=$(ssh docker "sudo docker logs macos-macos-1 2>&1 | grep -c 'loginwindow'" 2>/dev/null)
        if [ "$AFTER" -gt "$BEFORE" ] 2>/dev/null; then
            break
        fi
        echo -n "."
    done

    # Check results from THIS boot
    ROUTED=$(ssh docker "sudo docker logs --tail 200 macos-macos-1 2>&1 | grep -c '4/4 routed'" 2>/dev/null)
    CRASH=$(ssh docker "sudo docker logs --tail 200 macos-macos-1 2>&1 | grep -c 'panic'" 2>/dev/null)

    if [ "$ROUTED" -ge 1 ] && [ "$CRASH" -eq 0 ]; then
        PASS=$((PASS+1))
        echo " PASS (routed=$ROUTED)"
    else
        FAIL=$((FAIL+1))
        echo " FAIL (routed=$ROUTED crash=$CRASH)"
    fi

    # Stop VM
    ssh docker "sudo docker stop macos-macos-1" 2>/dev/null
    sleep 3
done

echo ""
echo "=== RESULTS: $PASS/20 pass, $FAIL/20 fail ==="
