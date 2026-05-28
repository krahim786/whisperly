//
//  whisperly-Bridging-Header.h
//  Whisperly
//
//  Exposes a small surface of Obj-C helpers to Swift. The only entry today is
//  WHObjCExceptionCatcher, used to safely wrap AVAudioEngine APIs that can
//  raise NSException (which Swift's do/catch can't intercept).
//

#import "Services/WHObjCExceptionCatcher.h"
