# Roblox Backend & Systems Showcase

This repository contains selected Luau systems I have developed for Roblox projects. It is intended to demonstrate my approach to backend architecture, networking, state management, procedural gameplay, persistence, optimization, and maintainable code structure.

The scripts included here are complete system examples rather than isolated snippets. Some project-specific assets, dependencies, remotes, and supporting modules have been excluded.

## Systems Included

### Matchmaking System

A scalable cross-server matchmaking framework supporting:

- MemoryStore-based server discovery
- Regional matchmaking and fallback regions
- Hidden MMR and expanding skill ranges
- Normal, Hardcore, Speedrun, and Ranked queues
- Party matchmaking
- Reserved server teleportation
- Capacity validation and overfill protection
- Teleport retries and automatic requeueing
- Ranked dodge warnings and temporary penalties
- Server heartbeat registration
- Matchmaking metrics and fill-time tracking

### Procedural Tile Framework

A modular environmental gameplay system featuring:

- State-driven tile behavior
- Normal, charging, dangerous, and recovery states
- Difficulty scaling across rooms
- Weighted procedural tile selection
- Hazard, movement, constraint, and neutral categories
- Anti-clustering and repetition penalties
- Surface-aware behavior for floors, walls, and ceilings
- Smooth visual interpolation and physical tile movement
- Pressure, heat, and player-triggered reactions
- Runtime effect and damage management

### Dynamic Room Rules

A framework for temporarily applying and safely cleaning up room-specific gameplay rules, including:

- Directional and reversed gravity
- Chaos gravity with timed directional changes
- Gravity-aware collision handling
- Pulse-wave hazard patterns
- Momentum and movement modifiers
- Runtime connection and instance tracking
- Deterministic cleanup when a room ends

### Season and Progression System

A persistent seasonal progression framework supporting:

- Free and premium reward tracks
- Configurable season durations
- Tier-based XP progression
- Daily login, run, and win rewards
- Daily XP limits
- Weekend XP multipliers
- Bonus objectives
- Reward claim validation
- Premium ownership checks
- Profile and DataStore integration

## Technical Focus

The code in this repository demonstrates experience with:

- Server-authoritative architecture
- Cross-server communication
- MemoryStoreService
- MessagingService
- DataStoreService
- TeleportService
- Procedural generation
- Weighted selection algorithms
- State machines
- Runtime cleanup and lifecycle management
- Type-safe Luau
- Modular system design
- Performance-conscious update loops
- Defensive validation and error handling

## Repository Structure

```text
src/
├── Matchmaking/
│   └── MatchmakingService.luau
│   └── RoomService.luau
├── Tiles/
│   ├── TileController.luau
│   └── TileTaxonomy.luau
│   └── TileGenerator.luau
├── Rules/
│   └── RuleController.luau
└── Progression/
    └── SeasonService.luau
    └── GlobalRank.luau
    └── RoomService.luau
