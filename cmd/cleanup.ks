// cmd/cleanup.ks - Free local kOS storage
// Usage with link: RUNPATH("0:/cmd/cleanup.ks").
// Usage cached:    RUNPATH("1:/cmd/cleanup.ks").

IF HOMECONNECTION:ISCONNECTED AND EXISTS("0:/lib/cleanup.ks") {
    RUNONCEPATH("0:/lib/cleanup.ks").
} ELSE IF EXISTS("1:/lib/cleanup.ksm") {
    RUNONCEPATH("1:/lib/cleanup.ksm").
} ELSE {
    RUNONCEPATH("1:/lib/cleanup.ks").
}

cleanupLocalVolume().
