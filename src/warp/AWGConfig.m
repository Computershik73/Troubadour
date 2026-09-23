//
//  AWGConfig.m
//  YouTube
//

#import "AWGConfig.h"
#import "AWGCrypto.h"

@implementation AWGConfig

+ (instancetype)configWithDefaults {
    AWGConfig *c = [[AWGConfig alloc] init];
    c.label = @"AmneziaWG";
    c.ipv4Address = @"10.2.0.2/32";
    c.ipv6Address = @"2a07:b944::2:2/128";
    c.dnsServers = @"1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001";
    c.mtu = 1280;
    c.allowedIPs = @"0.0.0.0/0, ::/0";
    c.junkCount = 4;
    c.junkMin = 40;
    c.junkMax = 70;
    c.s1 = 0;
    c.s2 = 0;
    c.s3 = 0;
    c.s4 = 0;
    c.h1 = 1;
    c.h2 = 2;
    c.h3 = 3;
    c.h4 = 4;
    return c;
}

#pragma mark - WARP reserved bytes

- (BOOL)hasReservedBytes {
    if (self.warpClientID.length == 0) return NO;
    return [AWGCrypto base64Decode:self.warpClientID].length == 3;
}

- (void)copyReservedBytes:(uint8_t *)out {
    if (!out) return;
    memset(out, 0, 3);
    if (self.warpClientID.length == 0) return;
    NSData *d = [AWGCrypto base64Decode:self.warpClientID];
    if (d.length == 3) memcpy(out, d.bytes, 3);
}

- (NSString *)wireguardConfigString {
    NSMutableString *s = [NSMutableString string];
    if (self.warpClientID.length > 0) {
        [s appendFormat:@"# ClientID = %@\n", self.warpClientID];
    }
    [s appendString:@"[Interface]\n"];
    [s appendFormat:@"PrivateKey = %@\n", self.privateKey ?: @""];
    [s appendFormat:@"Address = %@", self.ipv4Address ?: @""];
    if (self.ipv6Address.length > 0) {
        [s appendFormat:@", %@", self.ipv6Address];
    }
    [s appendString:@"\n"];
    if (self.dnsServers.length > 0) {
        [s appendFormat:@"DNS = %@\n", self.dnsServers];
    }
    [s appendFormat:@"MTU = %lu\n", (unsigned long)self.mtu];
    [s appendString:@"\n[Peer]\n"];
    [s appendFormat:@"PublicKey = %@\n", self.peerPublicKey ?: @""];
    [s appendFormat:@"AllowedIPs = %@\n", self.allowedIPs ?: @"0.0.0.0/0"];
    if (self.peerEndpoint.length > 0) {
        [s appendFormat:@"Endpoint = %@\n", self.peerEndpoint];
    }
    return s;
}

- (NSString *)obfuscatedConfigString {
    NSMutableString *s = [NSMutableString string];
    if (self.warpClientID.length > 0) {
        [s appendFormat:@"# ClientID = %@\n", self.warpClientID];
    }
    [s appendString:@"[Interface]\n"];
    [s appendFormat:@"PrivateKey = %@\n", self.privateKey ?: @""];
    [s appendFormat:@"Address = %@", self.ipv4Address ?: @""];
    if (self.ipv6Address.length > 0) {
        [s appendFormat:@", %@", self.ipv6Address];
    }
    [s appendString:@"\n"];
    if (self.dnsServers.length > 0) {
        [s appendFormat:@"DNS = %@\n", self.dnsServers];
    }
    [s appendFormat:@"MTU = %lu\n", (unsigned long)self.mtu];
    [s appendFormat:@"Jc = %lu\n", (unsigned long)self.junkCount];
    [s appendFormat:@"Jmin = %lu\n", (unsigned long)self.junkMin];
    [s appendFormat:@"Jmax = %lu\n", (unsigned long)self.junkMax];
    [s appendFormat:@"S1 = %lu\n", (unsigned long)self.s1];
    [s appendFormat:@"S2 = %lu\n", (unsigned long)self.s2];
    [s appendFormat:@"S3 = %lu\n", (unsigned long)self.s3];
    [s appendFormat:@"S4 = %lu\n", (unsigned long)self.s4];
    [s appendFormat:@"H1 = %lu\n", (unsigned long)self.h1];
    [s appendFormat:@"H2 = %lu\n", (unsigned long)self.h2];
    [s appendFormat:@"H3 = %lu\n", (unsigned long)self.h3];
    [s appendFormat:@"H4 = %lu\n", (unsigned long)self.h4];
    if (self.i1.length > 0) [s appendFormat:@"I1 = %@\n", self.i1];
    if (self.i2.length > 0) [s appendFormat:@"I2 = %@\n", self.i2];
    if (self.i3.length > 0) [s appendFormat:@"I3 = %@\n", self.i3];
    if (self.i4.length > 0) [s appendFormat:@"I4 = %@\n", self.i4];
    if (self.i5.length > 0) [s appendFormat:@"I5 = %@\n", self.i5];
    [s appendString:@"\n[Peer]\n"];
    [s appendFormat:@"PublicKey = %@\n", self.peerPublicKey ?: @""];
    [s appendFormat:@"AllowedIPs = %@\n", self.allowedIPs ?: @"0.0.0.0/0"];
    if (self.peerEndpoint.length > 0) {
        [s appendFormat:@"Endpoint = %@\n", self.peerEndpoint];
    }
    return s;
}

+ (instancetype)configFromWireguardString:(NSString *)string {
    if (!string) return nil;
    AWGConfig *c = [self configWithDefaults];
    BOOL inInterface = NO, inPeer = NO;
    for (NSString *rawLine in [string componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"#"]) {
            NSRange cid = [line rangeOfString:@"ClientID" options:NSCaseInsensitiveSearch];
            NSRange ceq = [line rangeOfString:@"="];
            if (cid.location != NSNotFound && ceq.location != NSNotFound && ceq.location > cid.location) {
                c.warpClientID = [[line substringFromIndex:ceq.location + 1]
                                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
            continue;
        }
        if (line.length == 0) continue;
        if ([line hasPrefix:@"["] && [line hasSuffix:@"]"]) {
            NSString *section = [[line substringWithRange:NSMakeRange(1, line.length - 2)] lowercaseString];
            inInterface = [section isEqualToString:@"interface"];
            inPeer = [section isEqualToString:@"peer"];
            continue;
        }
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *key = [[[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
        NSString *value = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (inInterface) {
            if ([key isEqualToString:@"privatekey"]) c.privateKey = value;
            else if ([key isEqualToString:@"address"]) c.ipv4Address = value;
            else if ([key isEqualToString:@"dns"]) c.dnsServers = value;
            else if ([key isEqualToString:@"mtu"]) c.mtu = (NSUInteger)[value integerValue];
            else if ([key isEqualToString:@"jc"]) c.junkCount = (NSUInteger)[value integerValue];
            else if ([key isEqualToString:@"jmin"]) c.junkMin = (NSUInteger)[value integerValue];
            else if ([key isEqualToString:@"jmax"]) c.junkMax = (NSUInteger)[value integerValue];
            else if ([key isEqualToString:@"s1"]) c.s1 = (NSUInteger)[value integerValue];
            else if ([key isEqualToString:@"s2"]) c.s2 = (NSUInteger)[value integerValue];
            else if ([key isEqualToString:@"s3"]) c.s3 = (NSUInteger)[value integerValue];
            else if ([key isEqualToString:@"s4"]) c.s4 = (NSUInteger)[value integerValue];
            else if ([key isEqualToString:@"h1"]) c.h1 = (NSUInteger)[value integerValue];
            else if ([key isEqualToString:@"h2"]) c.h2 = (NSUInteger)[value integerValue];
            else if ([key isEqualToString:@"h3"]) c.h3 = (NSUInteger)[value integerValue];
            else if ([key isEqualToString:@"h4"]) c.h4 = (NSUInteger)[value integerValue];
            else if ([key isEqualToString:@"i1"]) c.i1 = value;
            else if ([key isEqualToString:@"i2"]) c.i2 = value;
            else if ([key isEqualToString:@"i3"]) c.i3 = value;
            else if ([key isEqualToString:@"i4"]) c.i4 = value;
            else if ([key isEqualToString:@"i5"]) c.i5 = value;
        } else if (inPeer) {
            if ([key isEqualToString:@"publickey"]) c.peerPublicKey = value;
            else if ([key isEqualToString:@"presharedkey"]) c.presharedKey = value;
            else if ([key isEqualToString:@"allowedips"]) c.allowedIPs = value;
            else if ([key isEqualToString:@"endpoint"]) c.peerEndpoint = value;
        }
    }
    return c;
}

#pragma mark - NSCoding

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _privateKey = [coder decodeObjectForKey:@"privateKey"];
        _publicKey = [coder decodeObjectForKey:@"publicKey"];
        _presharedKey = [coder decodeObjectForKey:@"presharedKey"];
        _ipv4Address = [coder decodeObjectForKey:@"ipv4Address"];
        _ipv6Address = [coder decodeObjectForKey:@"ipv6Address"];
        _dnsServers = [coder decodeObjectForKey:@"dnsServers"];
        _mtu = (NSUInteger)[coder decodeIntegerForKey:@"mtu"];
        _peerPublicKey = [coder decodeObjectForKey:@"peerPublicKey"];
        _peerEndpoint = [coder decodeObjectForKey:@"peerEndpoint"];
        _allowedIPs = [coder decodeObjectForKey:@"allowedIPs"];
        _junkCount = (NSUInteger)[coder decodeIntegerForKey:@"junkCount"];
        _junkMin = (NSUInteger)[coder decodeIntegerForKey:@"junkMin"];
        _junkMax = (NSUInteger)[coder decodeIntegerForKey:@"junkMax"];
        _s1 = (NSUInteger)[coder decodeIntegerForKey:@"s1"];
        _s2 = (NSUInteger)[coder decodeIntegerForKey:@"s2"];
        _s3 = (NSUInteger)[coder decodeIntegerForKey:@"s3"];
        _s4 = (NSUInteger)[coder decodeIntegerForKey:@"s4"];
        _h1 = (NSUInteger)[coder decodeIntegerForKey:@"h1"];
        _h2 = (NSUInteger)[coder decodeIntegerForKey:@"h2"];
        _h3 = (NSUInteger)[coder decodeIntegerForKey:@"h3"];
        _h4 = (NSUInteger)[coder decodeIntegerForKey:@"h4"];
        _i1 = [coder decodeObjectForKey:@"i1"];
        _i2 = [coder decodeObjectForKey:@"i2"];
        _i3 = [coder decodeObjectForKey:@"i3"];
        _i4 = [coder decodeObjectForKey:@"i4"];
        _i5 = [coder decodeObjectForKey:@"i5"];
        _label = [coder decodeObjectForKey:@"label"];
        _preferredSNI = [coder decodeObjectForKey:@"preferredSNI"];
        _warpClientID = [coder decodeObjectForKey:@"warpClientID"];
        _preferredPorts = [coder decodeObjectForKey:@"preferredPorts"];
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.privateKey forKey:@"privateKey"];
    [coder encodeObject:self.publicKey forKey:@"publicKey"];
    [coder encodeObject:self.presharedKey forKey:@"presharedKey"];
    [coder encodeObject:self.ipv4Address forKey:@"ipv4Address"];
    [coder encodeObject:self.ipv6Address forKey:@"ipv6Address"];
    [coder encodeObject:self.dnsServers forKey:@"dnsServers"];
    [coder encodeInteger:(NSInteger)self.mtu forKey:@"mtu"];
    [coder encodeObject:self.peerPublicKey forKey:@"peerPublicKey"];
    [coder encodeObject:self.peerEndpoint forKey:@"peerEndpoint"];
    [coder encodeObject:self.allowedIPs forKey:@"allowedIPs"];
    [coder encodeInteger:(NSInteger)self.junkCount forKey:@"junkCount"];
    [coder encodeInteger:(NSInteger)self.junkMin forKey:@"junkMin"];
    [coder encodeInteger:(NSInteger)self.junkMax forKey:@"junkMax"];
    [coder encodeInteger:(NSInteger)self.s1 forKey:@"s1"];
    [coder encodeInteger:(NSInteger)self.s2 forKey:@"s2"];
    [coder encodeInteger:(NSInteger)self.s3 forKey:@"s3"];
    [coder encodeInteger:(NSInteger)self.s4 forKey:@"s4"];
    [coder encodeInteger:(NSInteger)self.h1 forKey:@"h1"];
    [coder encodeInteger:(NSInteger)self.h2 forKey:@"h2"];
    [coder encodeInteger:(NSInteger)self.h3 forKey:@"h3"];
    [coder encodeInteger:(NSInteger)self.h4 forKey:@"h4"];
    [coder encodeObject:self.i1 forKey:@"i1"];
    [coder encodeObject:self.i2 forKey:@"i2"];
    [coder encodeObject:self.i3 forKey:@"i3"];
    [coder encodeObject:self.i4 forKey:@"i4"];
    [coder encodeObject:self.i5 forKey:@"i5"];
    [coder encodeObject:self.label forKey:@"label"];
    [coder encodeObject:self.preferredSNI forKey:@"preferredSNI"];
    [coder encodeObject:self.warpClientID forKey:@"warpClientID"];
    [coder encodeObject:self.preferredPorts forKey:@"preferredPorts"];
}

@end
