# Bug Fix: ENABLE/DISABLE Commands Not Working Without Reboot

## The Problem

The ENABLE and DISABLE commands were not working without a reboot due to a fundamental logic flaw in the bypass mechanism.

### Root Cause

The original implementation used a bypass_switch set with a "magic MAC" approach:

**Old gatekeeper.nft rule:**
```nft
add rule inet fw4 gatekeeper_forward ether saddr @bypass_switch accept
```

**Old DISABLE command:**
```bash
nft "add element inet fw4 bypass_switch { ff:ff:ff:ff:ff:ff }"
```

**The flaw:** The firewall rule checked if the **packet's source MAC address** was in the bypass_switch set. But when DISABLE added `ff:ff:ff:ff:ff:ff` to the set, no real device has that MAC address (it's the broadcast MAC), so the bypass rule never matched any actual traffic.

The intent was: "If bypass_switch contains the magic MAC, accept ALL traffic"
The implementation did: "If packet source MAC equals magic MAC, accept packet"

These are completely different conditions!

## The Solution

### Changes Made

1. **Removed bypass_switch set** from `gatekeeper.nft` (no longer needed)
2. **Updated DISABLE command** to flush the gatekeeper_forward chain:
   ```bash
   nft flush chain inet fw4 gatekeeper_forward
   ```
   - Removes all filter rules from the chain
   - Chain still exists but has no rules, so all traffic passes
   - Works immediately, no reboot required

3. **Updated ENABLE command** to reload firewall:
   ```bash
   fw4 reload
   ```
   - Triggers gatekeeper.nft to recreate all filter rules
   - Restores normal filtering behavior
   - Works immediately, no reboot required

4. **Updated STATUS command** to detect bypass by checking rule count:
   ```bash
   RULE_COUNT=$(nft list chain inet fw4 gatekeeper_forward 2>/dev/null | grep -c "drop\|accept")
   if [ "$RULE_COUNT" = "0" ]; then
       BYPASS="🔓 DISABLED"
   else
       BYPASS="🛡️ ENABLED"
   fi
   ```

### Files Modified

- `gatekeeper.nft`: Removed bypass_switch set, updated comments
- `tg_bot.sh`: Rewrote ENABLE/DISABLE/STATUS commands
- `CLAUDE.md`: Updated documentation to reflect new mechanism

### Why This Works

1. **DISABLE** immediately removes all filtering by flushing the chain
2. **ENABLE** immediately restores filtering by reloading the firewall
3. No reboot needed - we're manipulating the active nftables ruleset
4. Simple and reliable - uses standard OpenWrt firewall reload mechanism

## Testing

To test the fix:

1. Deploy the updated files:
   ```bash
   ./deploy.sh 192.168.1.1
   ```

2. Test DISABLE:
   ```
   Send "DISABLE" in Telegram
   Verify message: "🔓 Gatekeeper Disabled - All devices now have network access"
   ```

3. Verify bypass is active:
   ```bash
   ssh root@192.168.1.1
   nft list chain inet fw4 gatekeeper_forward
   # Should show chain exists but has no rules
   ```

4. Test ENABLE:
   ```
   Send "ENABLE" in Telegram
   Verify message: "🛡️ Gatekeeper Enabled - Filtering restored"
   ```

5. Verify filtering is restored:
   ```bash
   nft list chain inet fw4 gatekeeper_forward
   # Should show all filter rules (static_macs, approved_macs, drop)
   ```

6. Test STATUS:
   ```
   Send "STATUS" in Telegram
   Should show: "🛡️ Gatekeeper: ENABLED" or "🔓 DISABLED" correctly
   ```

## Migration Notes

If you have existing installations:

1. The old bypass_switch set is harmless but unused - it will remain in the ruleset
2. After deploying the fix, DISABLE/ENABLE will work correctly
3. You can manually remove the old bypass_switch entries:
   ```bash
   nft flush set inet fw4 bypass_switch
   ```

## Additional Benefits

- Simplified firewall architecture (4 sets instead of 5)
- More reliable bypass mechanism
- Clearer command feedback in Telegram
- Standard OpenWrt firewall reload behavior
