//
//  WHObjCExceptionCatcher.h
//  Whisperly
//
//  Tiny Obj-C bridge that lets Swift call a block and recover from any
//  NSException it raises. AVAudioEngine APIs like `installTap` raise NSException
//  on some failure paths (e.g. validating that a Bluetooth bus's reported format
//  is actually valid for tapping). Swift's `do/catch` can't catch NSException —
//  unhandled, it propagates to the C++ runtime and aborts the process via
//  `std::terminate`. Wrapping the call in `@try`/`@catch` here turns the
//  exception into a return value that Swift CAN handle.
//
//  Use only as a last-ditch safety net around system APIs whose exception
//  behavior we can't otherwise prevent. Do NOT use this as a substitute for
//  ordinary error handling.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`. Returns nil if the block returned normally; returns the
/// caught NSException if the block raised one. The block is invoked
/// synchronously on the calling thread.
NSException * _Nullable WHTryBlock(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
