//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift Cluster Membership open source project
//
// Copyright (c) 2018-2019 Apple Inc. and the Swift Cluster Membership project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.md for the list of Swift Cluster Membership project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import struct Dispatch.DispatchTime // for time source overriding
import Logging

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Settings

extension SWIM {
    public struct Settings {
        public static var `default`: Settings {
            .init()
        }

        public var logger: Logger = Logger(label: "swim")

        public var logLevel: Logger.Level {
            get {
                self.logger.logLevel
            }
            set {
                self.logger.logLevel = newValue
            }
        }

        /// Gossip settings
        public var gossip: SWIMGossipSettings = .default

        /// Settings of the Lifeguard extensions to the SWIM protocol.
        ///
        /// - SeeAlso: `SWIMLifeguardSettings` for in depth documentation about it.
        public var lifeguard: SWIMLifeguardSettings = .default

        /// Number of indirect probes that will be issued once a direct ping probe has failed to reply in time with an ack.
        ///
        /// In case of small clusters where nr. of neighbors is smaller than this value, the most neighbors available will
        /// be asked to issue an indirect probe. E.g. a 3 node cluster, configured with `indirectChecks = 3` has only `1`
        /// remaining node it can ask for an indirect probe (since 1 node is ourselves, and 1 node is the potentially suspect node itself).
        public var indirectProbeCount: Int = 3 {
            willSet {
                precondition(newValue >= 0, "`indirectChecks` MUST be >= 0. It is recommended to have it be no lower than 3.")
            }
        }

        /// Interval at which gossip messages should be issued.
        /// This property sets only a base value of probe interval, which will later be multiplied by `SWIM.Instance.localHealthMultiplier`.
        /// - SeeAlso: `maxLocalHealthMultiplier`
        /// Every `interval` a `fan-out` number of gossip messages will be sent. // TODO which fanout, better docs
        public var probeInterval: SWIMTimeAmount = .seconds(1)

        /// Time amount after which a sent ping without ack response is considered timed-out.
        /// This drives how a node becomes a suspect, by missing such ping/ack rounds.
        ///
        /// This property sets only a base timeout value, which is later multiplied by `localHealthMultiplier`
        /// Note that after an initial ping/ack timeout, secondary indirect probes are issued,
        /// and only after exceeding `suspicionTimeoutPeriodsMax` shall the node be declared as `.unreachable`,
        /// which results in an `Cluster.MemberReachabilityChange` `Cluster.Event` which downing strategies may act upon.
        ///
        /// - SeeAlso: `lifeguard.maxLocalHealthMultiplier`
        public var pingTimeout: SWIMTimeAmount = .milliseconds(300)

        /// This is not a part of public API. SWIM is using time to schedule pings/calculate timeouts.
        /// When designing tests one may want to simulate scenarios when events are coming in particular order.
        /// Doing this will require some control over SWIM's notion of time.
        ///
        /// This property allows to override the `.now()` function.
        var timeSourceNanos: () -> Int64 = { () -> Int64 in
            Int64(min(UInt64(Int64.max), DispatchTime.now().uptimeNanoseconds))
        }

        /// When enabled traces _all_ incoming SWIM protocol communication (remote messages).
        /// These logs will contain SWIM.Instance metadata, as offered by `SWIM.Instance.metadata`.
        // TODO: how to make this nicely dynamically changeable during runtime
        #if TRACELOG_SWIM
        public var traceLogLevel: Logger.Level? = .warning
        #else
        public var traceLogLevel: Logger.Level?
        #endif
    }
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Gossip Settings

public struct SWIMGossipSettings {
    public static var `default`: SWIMGossipSettings {
        .init()
    }

    // TODO: investigate size of messages and find good default
    /// Max number of messages included in any gossip payload
    public var maxNumberOfMessages: Int = 20

    public var maxGossipCountPerMessage: Int = 6
}

// ==== ----------------------------------------------------------------------------------------------------------------
// MARK: SWIM Lifeguard extensions Settings

/// Lifeguard is a set of extensions to SWIM that helps reducing false positive failure detections
///
/// - SeeAlso: [Lifeguard: Local Health Awareness for More Accurate Failure Detection](https://arxiv.org/pdf/1707.00788.pdf)
public struct SWIMLifeguardSettings {
    public static var `default`: SWIMLifeguardSettings {
        .init()
    }

    /// Local health multiplier is a part of Lifeguard extensions to SWIM.
    /// It will increase local probe interval and probe timeout if the instance is not processing messages in timely manner.
    /// This property will define the upper limit to local health multiplier.
    ///
    /// Must be greater than 0. To effectively disable the LHM extension you may set this to `1`.
    ///
    /// - SeeAlso: [Lifeguard IV.A. Local Health Multiplier (LHM)](https://arxiv.org/pdf/1707.00788.pdf)
    public var maxLocalHealthMultiplier: Int = 8 {
        willSet {
            precondition(newValue >= 0, "Local health multiplier MUST BE >= 0")
        }
    }

    /// Suspicion timeouts are specified as number of probe intervals.
    ///
    /// E.g. a `suspicionTimeoutMax = .seconds(10)` means that a suspicious node will be escalated as `.unreachable`  at most after approximately 10 seconds. Suspicion timeout will decay logarithmically to `suspicionTimeoutMin`
    /// with additional suspicions arriving. When no additional suspicions present, suspicion timeout will equal `suspicionTimeoutMax`
    ///
    /// ### Modification:
    /// We introduce an extra state of "unreachable" is introduced, which is signalled to a high-level membership implementation,
    /// which may then confirm it, then leading the SWIM membership to mark the given member as `.dead`. Unlike the original SWIM/Lifeguard
    /// implementations which proceed to `.dead` automatically. This separation allows running with SWIM failure detection in an "informational"
    /// mode.
    ///
    /// Once it is confirmed dead by the high-level membership (e.g. immediately, or after an additional grace period, or vote),
    /// it will be marked `.dead` in SWIM, and `.down` in the high-level membership.
    ///
    /// - SeeAlso: [Lifeguard IV.B. Local Health Aware Suspicion (LHA-Suspicion)](https://arxiv.org/pdf/1707.00788.pdf)
    public var suspicionTimeoutMax: SWIMTimeAmount = .seconds(10) {
        willSet {
            precondition(newValue >= self.suspicionTimeoutMin, "`suspicionTimeoutMax` MUST BE >= `suspicionTimeoutMin`")
        }
    }

    /// Suspicion timeouts are specified as number of probe intervals.
    ///
    /// E.g. a `suspicionTimeoutMin = .seconds(3)` means that a suspicious node will be escalated as `.unreachable` at least after approximately 3 seconds.
    /// Suspicion timeout will decay logarithmically from `suspicionTimeoutMax` / with additional suspicions arriving.
    /// When number of suspicions reach `maxIndependentSuspicions`, suspicion timeout will equal `suspicionTimeoutMin`
    ///
    /// ### Modification:
    /// An extra state of "unreachable" is introduced, which is signalled to a high-level membership implementation,
    /// which may then confirm it, then leading the SWIM membership to mark the given member as `.dead`. Unlike the original SWIM/Lifeguard
    /// implementations which proceed to `.dead` automatically. This separation allows running with SWIM failure detection in an "informational"
    /// mode.
    ///
    /// Once it is confirmed dead by the high-level membership (e.g. immediately, or after an additional grace period, or vote),
    /// it will be marked `.dead` in swim, and `.down` in the high-level membership.
    ///
    /// - SeeAlso: [Lifeguard IV.B. Local Health Aware Suspicion (LHA-Suspicion)](https://arxiv.org/pdf/1707.00788.pdf)
    public var suspicionTimeoutMin: SWIMTimeAmount = .seconds(3) {
        willSet {
            precondition(newValue <= self.suspicionTimeoutMax, "`suspicionTimeoutMin` MUST BE <= `suspicionTimeoutMax`")
        }
    }

    /// A number of independent suspicions required for a suspicion timeout to fully decay to a minimal value.
    /// When set to 1 will effectively disable LHA-suspicion.
    public var maxIndependentSuspicions = 4 {
        willSet {
            precondition(newValue > 0, "`settings.cluster.swim.maxIndependentSuspicions` MUST BE > 0")
        }
    }
}
