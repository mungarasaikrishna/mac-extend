#import "DisplayBridge.h"
#import <Security/CipherSuite.h>

void ConfigurePairedTLS(sec_protocol_options_t options, NSData *key) {
    static const char identity[] = "iMacExtendedDisplay-v1";
    sec_protocol_options_set_min_tls_protocol_version(options, tls_protocol_version_TLSv12);
    sec_protocol_options_set_max_tls_protocol_version(options, tls_protocol_version_TLSv12);
    sec_protocol_options_append_tls_ciphersuite(options, (tls_ciphersuite_t)TLS_PSK_WITH_AES_128_GCM_SHA256);
    dispatch_data_t keyData = dispatch_data_create(key.bytes, key.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    dispatch_data_t identityData = dispatch_data_create(identity, sizeof(identity) - 1,
                                                        NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    sec_protocol_options_add_pre_shared_key(options, keyData, identityData);
}
