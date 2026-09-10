package com.rspetstop.driverapp;

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(DriverTrackingPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
