// Shared electrical readouts; no steering, deployment or solar search.
@LAZYGLOBAL OFF.

LOCAL FUNCTION _shipElectricChargeAmount {
    LOCAL stored IS 0.
    FOR res IN SHIP:RESOURCES {
        IF res:NAME = "ElectricCharge" {
            SET stored TO stored + res:AMOUNT.
        }
    }
    RETURN stored.
}

LOCAL FUNCTION _shipElectricChargeCapacity {
    LOCAL cap IS 0.
    FOR res IN SHIP:RESOURCES {
        IF res:NAME = "ElectricCharge" {
            SET cap TO cap + res:CAPACITY.
        }
    }
    RETURN cap.
}

GLOBAL FUNCTION shipPowerFraction {
    LOCAL cap IS _shipElectricChargeCapacity().
    IF cap > 0 { RETURN _shipElectricChargeAmount() / cap. }
    RETURN 1.
}

// True when the ship's net ElectricCharge rises over dT seconds.
// minDelta is in EC units and filters tiny readout jitter.
GLOBAL FUNCTION shipBatteriesCharging {
    PARAMETER dT IS 5.
    PARAMETER minDelta IS 0.01.

    IF _shipElectricChargeCapacity() <= 0 { RETURN FALSE. }
    LOCAL startEc IS _shipElectricChargeAmount().
    IF dT > 0 { WAIT dT. }
    RETURN _shipElectricChargeAmount() > startEc + minDelta.
}
