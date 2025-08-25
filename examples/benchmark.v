import gc
import time

fn main() {
	println('V Garbage Collector Benchmark')
	println('=============================')

	// Test different heap sizes
	heap_sizes := [1 * 1024 * 1024, 5 * 1024 * 1024, 10 * 1024 * 1024, 50 * 1024 * 1024]

	for heap_size in heap_sizes {
		println('\nTesting with ${heap_size / (1024 * 1024)}MB heap:')
		benchmark_gc(u32(heap_size))
	}
}

fn benchmark_gc(heap_size u32) {
	mut collector := gc.new_garbage_collector(heap_size)
	defer { collector.destroy() }

	// Benchmark allocation performance
	start_time := time.now()

	allocation_count := 1000
	allocation_size := u32(1024)

	for i in 0 .. allocation_count {
		ptr := collector.alloc(allocation_size)
		if ptr == unsafe { nil } {
			println('Allocation failed at iteration ${i}')
			break
		}
	}

	allocation_time := time.since(start_time)

	// Force GC and measure time
	gc_start := time.now()
	collector.force_collect()
	gc_time := time.since(gc_start)

	stats := collector.get_stats()

	println('  Allocations:\t\t ${allocation_count} x ${allocation_size} bytes')
	println('  Allocation time:\t ${allocation_time.microseconds()}μs')
	println('  GC time:\t\t ${gc_time.microseconds()}μs')
	println('  Total allocated:\t ${stats.total_allocated} bytes')
	println('  Total freed:\t\t ${stats.total_freed} bytes')
	println('  GC runs:\t\t ${stats.gc_count}')
	println('  Heap utilization:\t ${f64(stats.heap_used) / f64(stats.heap_size) * 100:.1f}%')

	// Calculate performance metrics
	alloc_rate := f64(allocation_count) / f64(allocation_time.microseconds()) * 1000000
	println('  Allocation rate:\t ${alloc_rate:.0f} allocs/sec')
}
