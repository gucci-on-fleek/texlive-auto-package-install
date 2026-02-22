#ifdef __GNUC__ // (added)
    #pragma GCC diagnostic push // (added)
    #pragma GCC diagnostic ignored "-Wunused-function" // (added)
#endif // (added)

#include "hydrogen.h"

#include "common.h"
#include "hydrogen_p.h"

#include "random.h"

#include "core.h"
#include "gimli-core.h"

#include "hash.h"
// #include "kdf.h" // (omitted)
// #include "secretbox.h" // (omitted)

#include "x25519.h"

// #include "kx.h" // (omitted)
// #include "pwhash.h" // (omitted)
#include "sign.h"

#ifdef __GNUC__ // (added)
    #pragma GCC diagnostic pop // (added)
#endif // (added)
