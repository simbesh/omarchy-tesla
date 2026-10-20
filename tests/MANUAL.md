# Panel checks

After installing and enabling `simbesh.teslamate`:

1. Open the panel. Check map, battery, range, temperatures and tyre units against TeslaMate.
2. Check that no route displays “No active navigation route”. With real navigation active,
   confirm the destination and local arrival time after a live route update.
3. Disconnect the broker or network. Check that the error appears and the driving indicator
   stops. Restore connectivity and check automatic recovery.
4. Change the broker or vehicle topic in settings. Verify reconnection and that readings from
   the previous vehicle disappear.
5. Test the presentation without publishing to MQTT:

   ```bash
   omarchy-shell simbesh.teslamate.test drive 60 90
   omarchy-shell simbesh.teslamate.test navigate "Test destination" 12
   omarchy-shell simbesh.teslamate.test park
   omarchy-shell simbesh.teslamate.test live
   ```

   Synthetic panel state ignores incoming readings until `live` reconnects. Departure
   notifications follow the widget's notification setting during these checks.
6. Check the popup under light and dark themes and at the minimum panel width. Confirm
   a long destination fits or wraps, and that the reconnect and maps buttons remain accessible.
