from .ahasher import ahash
from .key_eq import eq
from .keys_container import KeyRef, KeysContainer
from .single_key_builder import SingleKeyBuilder
from .sparse_array import SparseArray
from math.bit import ctpop, bit_length

struct MultiDict[
    V: CollectionElement, 
    hash: fn(KeyRef) -> UInt64 = ahash,
    KeyCountType: DType = DType.uint32,
    NextKeyCountType: DType = DType.uint16,
    KeyOffsetType: DType = DType.uint32,
    caching_hashes: Bool = True,
](Sized):
    var keys: KeysContainer[KeyOffsetType]
    var key_hashes: DTypePointer[KeyCountType]
    var values: List[V]
    var next_values_index: SparseArray[NextKeyCountType]
    var next_values: List[V]
    var next_next_values_index: SparseArray[NextKeyCountType]
    var key_map: DTypePointer[KeyCountType]
    var count: Int
    var capacity: Int
    var key_builder: SingleKeyBuilder

    fn __init__(inout self, capacity: Int = 16):
        constrained[
            KeyCountType == DType.uint8 or 
            KeyCountType == DType.uint16 or 
            KeyCountType == DType.uint32 or 
            KeyCountType == DType.uint64,
            "KeyCountType needs to be an unsigned integer"
        ]()
        constrained[
            NextKeyCountType == DType.uint8 or 
            NextKeyCountType == DType.uint16 or 
            NextKeyCountType == DType.uint32 or 
            NextKeyCountType == DType.uint64,
            "NextKeyCountType needs to be an unsigned integer"
        ]()
        self.count = 0
        if capacity <= 8:
            self.capacity = 8
        else:
            var icapacity = Int64(capacity)
            self.capacity = capacity if ctpop(icapacity) == 1 else
                            1 << (bit_length(icapacity)).to_int()
        self.keys = KeysContainer[KeyOffsetType](capacity)
        self.key_builder = SingleKeyBuilder()
        @parameter
        if caching_hashes:
            self.key_hashes = DTypePointer[KeyCountType].alloc(self.capacity)
        else:
            self.key_hashes = DTypePointer[KeyCountType].alloc(0)
        self.values = List[V](capacity)
        self.key_map = DTypePointer[KeyCountType].alloc(self.capacity)
        memset_zero(self.key_map, self.capacity)
        #TODO: Think about having an optional here or an empty List
        self.next_values = List[V]()
        self.next_values_index = SparseArray[NextKeyCountType]()
        self.next_next_values_index = SparseArray[NextKeyCountType]()

    fn __copyinit__(inout self, existing: Self):
        self.count = existing.count
        self.capacity = existing.capacity
        self.keys = existing.keys
        self.key_builder = self.key_builder
        @parameter
        if caching_hashes:
            self.key_hashes = DTypePointer[KeyCountType].alloc(self.capacity)
            memcpy(self.key_hashes, existing.key_hashes, self.capacity)
        else:
            self.key_hashes = DTypePointer[KeyCountType].alloc(0)
        self.values = existing.values
        self.key_map = DTypePointer[KeyCountType].alloc(self.capacity)
        memcpy(self.key_map, existing.key_map, self.capacity)
        self.next_values = existing.next_values
        self.next_values_index = existing.next_values_index 
        self.next_next_values_index = existing.next_next_values_index 

    fn __moveinit__(inout self, owned existing: Self):
        self.count = existing.count
        self.capacity = existing.capacity
        self.keys = existing.keys^
        self.key_builder = existing.key_builder^
        self.key_hashes = existing.key_hashes
        self.values = existing.values^
        self.key_map = existing.key_map
        self.next_values = existing.next_values^
        self.next_values_index = existing.next_values_index^
        self.next_next_values_index = existing.next_next_values_index^

    fn __del__(owned self):
        self.key_map.free()
        self.key_hashes.free()

    fn __len__(self) -> Int:
        return self.count

    fn put[T: Keyable](inout self, key: T, value: V) raises:
        if self.count / self.capacity >= 0.87:
            self._rehash()
        key.accept(self.keys)
        self.keys.end_key()
        var key_ref = self.keys.get_last()

        var key_hash = hash(key_ref).cast[KeyCountType]()
        var modulo_mask = self.capacity - 1
        var key_map_index = (key_hash & modulo_mask).to_int()
        while True:
            var key_index = self.key_map.load(key_map_index).to_int()
            if key_index == 0:
                @parameter
                if caching_hashes:
                    self.key_hashes.store(key_map_index, key_hash)
                self.values.append(value)
                self.count += 1
                self.key_map.store(key_map_index, SIMD[KeyCountType, 1](self.keys.count))
                return
            @parameter
            if caching_hashes:
                var other_key_hash = self.key_hashes[key_map_index]
                if other_key_hash == key_hash:
                    var other_key = self.keys[key_index - 1]
                    if eq(other_key, key_ref):
                        self._add_next(value, key_index)
                        return
            else:
                var other_key = self.keys[key_index - 1]
                if eq(other_key, key_ref):
                    self._add_next(value, key_index)
                    return
            
            key_map_index = (key_map_index + 1) & modulo_mask

    @always_inline
    fn _add_next(inout self, value: V, key_index: Int):
        self.next_values.append(value)
        var next_index = self.next_values_index.get(key_index - 1)
        if not next_index:
            self.next_values_index[key_index - 1] = len(self.next_values) - 1
        else:
            var index = next_index.value().to_int()
            var next_next_index = self.next_next_values_index.get(index)
            while next_next_index:
                index = next_next_index.value().to_int()
                next_next_index = self.next_next_values_index.get(index)
            self.next_next_values_index[index] = len(self.next_values) - 1
        self.keys.drop_last()

    @always_inline
    fn _rehash(inout self) raises:
        var old_key_map = self.key_map
        var old_capacity = self.capacity
        self.capacity <<= 1
        var mask_capacity = self.capacity >> 3
        self.key_map = DTypePointer[KeyCountType].alloc(self.capacity)
        memset_zero(self.key_map, self.capacity)
        
        var key_hashes = self.key_hashes
        @parameter
        if caching_hashes:
            key_hashes = DTypePointer[KeyCountType].alloc(self.capacity)
            
        var modulo_mask = self.capacity - 1
        for i in range(old_capacity):
            if old_key_map[i] == 0:
                continue
            var key_hash = SIMD[KeyCountType, 1](0)
            @parameter
            if caching_hashes:
                key_hash = self.key_hashes[i]
            else:
                key_hash = hash(self.keys[(old_key_map[i] - 1).to_int()]).cast[KeyCountType]()

            var key_map_index = (key_hash & modulo_mask).to_int()

            var searching = True
            while searching:
                var key_index = self.key_map.load(key_map_index).to_int()

                if key_index == 0:
                    self.key_map.store(key_map_index, old_key_map[i])
                    searching = False
                else:
                    key_map_index = (key_map_index + 1) & modulo_mask
            @parameter
            if caching_hashes:
                key_hashes[key_map_index] = key_hash  
        
        @parameter
        if caching_hashes:
            self.key_hashes.free()
            self.key_hashes = key_hashes
        old_key_map.free()

    @always_inline
    fn get[T: Keyable](inout self, key: T) raises -> List[V]:
        var result = List[V]()
        self.key_builder.reset()
        key.accept(self.key_builder)
        var key_ref = self.key_builder.get_key()
        var key_index = self._find_key_index(key_ref)
        if key_index == 0:
            return result
        result.append(self.values[key_index - 1])
        var next_index = self.next_values_index.get(key_index - 1)
        if not next_index:
            return result
        var index = next_index.value().to_int()
        result.append(self.next_values[index])
        var next_next_index = self.next_next_values_index.get(index)
        while next_next_index:
            index = next_next_index.value().to_int()
            result.append(self.next_values[index])
            next_next_index = self.next_next_values_index.get(index)
        return result

    fn _find_key_index(self, key_ref: KeyRef) raises -> Int:
        var key_hash = hash(key_ref).cast[KeyCountType]()
        var modulo_mask = self.capacity - 1
        var key_map_index = (key_hash & modulo_mask).to_int()
        while True:
            var key_index = self.key_map.load(key_map_index).to_int()
            if key_index == 0:
                return key_index
            @parameter
            if caching_hashes:
                var other_key_hash = self.key_hashes[key_map_index]
                if key_hash == other_key_hash:
                    var other_key = self.keys[key_index - 1]
                    if eq(other_key, key_ref):
                        return key_index
            else:
                var other_key = self.keys[key_index - 1]
                if eq(other_key, key_ref):
                    return key_index
            key_map_index = (key_map_index + 1) & modulo_mask

    fn debug(self) raises:
        print("Dict count:", self.count, "and capacity:", self.capacity)
        print("KeyMap:")
        for i in range(self.capacity):
            var end = ", " if i < self.capacity - 1 else ""
            print(self.key_map.load(i), end=end)
        print("Keys:")
        self.keys.print_keys()
        @parameter
        if caching_hashes:
            print("KeyHashes:")
            for i in range(self.capacity):
                var end = ", " if i < self.capacity - 1 else ""
                if self.key_map.load(i) > 0:
                    print(self.key_hashes.load(i), end=end)
                else:
                    print(0, end=end)
        print("Next Values:")
        self.next_values_index.debug()
        print("Next Next Values:")
        self.next_next_values_index.debug()