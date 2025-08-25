# V Language Garbage Collector

A conservative mark-and-sweep garbage collector implementation for the V programming language with heap partitioning to reduce memory fragmentation.

## Features

- **Conservative Mark-and-Sweep**: Implements the classic mark-and-sweep garbage collection algorithm
- **Heap Partitioning**: Reduces memory fragmentation using multiple heap partitions
- **Automatic Collection**: Triggers garbage collection automatically based on heap usage
- **Configurable**: Customizable heap size, partition count, and collection thresholds
- **Statistics**: Detailed GC performance statistics and monitoring

## Installation

```bash
git clone <repository-url>
cd v-garbage-collector
```

## Usage

```v
import gc

// Initialize garbage collector with custom heap size
mut collector := gc.new_garbage_collector(32 * 1024 * 1024) // 32MB
defer { collector.destroy() }

// Allocate memory
ptr := collector.alloc(1024)

// Add roots for persistent data
mut global_data := [100]int{}
collector.add_root(voidptr(&global_data[0]), sizeof(global_data))

// Force garbage collection if needed
collector.force_collect()

// Get statistics
stats := collector.get_stats()
println('GC runs: ${stats.gc_count}, Heap used: ${stats.heap_used}')
```

## Architecture
### Mark-and-Sweep Algorithm
1. **Mark Phase**: Scans from root set (stack, registers, user-defined roots) and marks all reachable objects
2. **Sweep Phase**: Frees all unmarked objects and coalesces adjacent free blocks

### Heap Partitioning
The heap is divided into multiple partitions to:
- Reduce fragmentation through better size-class allocation
- Improve cache locality
- Enable parallel collection in future versions

### Conservative Scanning
Since V doesn't provide complete type information at runtime, the collector:
- Treats any pointer-sized aligned value as a potential pointer
- Scans the entire stack conservatively
- Maintains user-defined root sets for known pointer locations

## Configuration

```v
const (
    default_heap_size = 32 * 1024 * 1024  // 32MB default heap
    default_partitions = 8                // 8 heap partitions
    gc_trigger_threshold = 0.75           // Trigger GC at 75% heap usage
    min_object_size = 16                  // Minimum object alignment
)
```

## Testing

```v
v test .
```

## Benchmarking

```v
v run benchmark.v
```

## Examples
See for comprehensive usage examples including: `example.v`
- Basic memory allocation
- Linked list creation and collection
- Root set management
- Performance monitoring

## Performance
The garbage collector is designed for:
- Low pause times through partitioned heap management
- Reduced fragmentation via free block coalescing
- Configurable collection frequency
- Minimal runtime overhead

## License
MIT License - see LICENSE file for details.
