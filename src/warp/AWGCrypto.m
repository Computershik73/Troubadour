//
//  AWGCrypto.m
//  YouTube
//

#import "AWGCrypto.h"
#import "monocypher.h"

@implementation AWGCrypto

+ (NSData *)generatePrivateKey {
    uint8_t priv[32];
    // iOS 6 has no SecRandomCopyBytes — read from /dev/urandom like OpenSSL does.
    FILE *f = fopen("/dev/urandom", "r");
    if (!f) return nil;
    size_t n = fread(priv, 1, sizeof(priv), f);
    fclose(f);
    if (n != sizeof(priv)) return nil;
    // Clamp per RFC 7748 (X25519)
    priv[0]  &= 248;
    priv[31] &= 127;
    priv[31] |= 64;
    return [NSData dataWithBytes:priv length:32];
}

+ (NSData *)publicKeyFromPrivateKey:(NSData *)privateKey {
    if ([privateKey length] != 32) return nil;
    uint8_t pub[32];
    crypto_x25519_public_key(pub, [privateKey bytes]);
    return [NSData dataWithBytes:pub length:32];
}

+ (NSString *)base64Encode:(NSData *)data {
    if (!data) return nil;
    static const char tbl[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    NSMutableString *out = [NSMutableString string];
    const uint8_t *bytes = [data bytes];
    NSUInteger len = [data length];
    NSUInteger i = 0;
    while (i + 3 <= len) {
        uint32_t v = (bytes[i] << 16) | (bytes[i+1] << 8) | bytes[i+2];
        [out appendFormat:@"%c%c%c%c",
            tbl[(v >> 18) & 63], tbl[(v >> 12) & 63],
            tbl[(v >> 6) & 63], tbl[v & 63]];
        i += 3;
    }
    if (i < len) {
        uint32_t v = bytes[i] << 16;
        int rem = (int)(len - i);
        if (rem == 2) v |= bytes[i+1] << 8;
        [out appendFormat:@"%c%c", tbl[(v >> 18) & 63], tbl[(v >> 12) & 63]];
        if (rem == 2) [out appendFormat:@"%c", tbl[(v >> 6) & 63]];
        else [out appendString:@"="];
        [out appendString:@"="];
    }
    return out;
}

+ (NSData *)base64Decode:(NSString *)string {
    if (!string) return nil;
    static const uint8_t dec[256] = {
        ['A']=0,['B']=1,['C']=2,['D']=3,['E']=4,['F']=5,['G']=6,['H']=7,['I']=8,['J']=9,
        ['K']=10,['L']=11,['M']=12,['N']=13,['O']=14,['P']=15,['Q']=16,['R']=17,['S']=18,
        ['T']=19,['U']=20,['V']=21,['W']=22,['X']=23,['Y']=24,['Z']=25,
        ['a']=26,['b']=27,['c']=28,['d']=29,['e']=30,['f']=31,['g']=32,['h']=33,['i']=34,
        ['j']=35,['k']=36,['l']=37,['m']=38,['n']=39,['o']=40,['p']=41,['q']=42,['r']=43,
        ['s']=44,['t']=45,['u']=46,['v']=47,['w']=48,['x']=49,['y']=50,['z']=51,
        ['0']=52,['1']=53,['2']=54,['3']=55,['4']=56,['5']=57,['6']=58,['7']=59,['8']=60,
        ['9']=61,['+']=62,['/']=63
    };
    NSMutableData *data = [NSMutableData data];
    const char *s = [string UTF8String];
    if (!s) return nil;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; s[i]; i++) {
        uint8_t c = (uint8_t)s[i];
        if (c == '=' || c == ' ' || c == '\n' || c == '\r' || c == '\t') break;
        acc = (acc << 6) | dec[c];
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            uint8_t b = (uint8_t)((acc >> bits) & 0xff);
            [data appendBytes:&b length:1];
        }
    }
    return data;
}

@end
