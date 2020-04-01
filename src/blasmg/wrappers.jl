function cublasMgCreate()
    handle = Ref{cublasMgHandle_t}()
    cublasMgCreate(handle)
    return handle[]
end

function allocateBuffers(grid, n_row_devs, n_col_devs, num_devices::Int, deviceIdsGrid, streams, row_block_size, col_block_size, desc, D)
    buffers  = Vector{CuPtr{Cvoid}}(undef, num_devices)
    numRows  = Vector{Int64}(undef, num_devices)
    numCols  = Vector{Int64}(undef, num_devices)
    typesize = sizeof(eltype(D))
    cudaLibMgGetLocalMatrixDimensions(desc, numRows, numCols)
    llds = Vector{Int64}(undef, num_devices)
    sub_Ds = Vector{Vector}(undef, num_devices)
    for (di, dev) in enumerate(deviceIdsGrid)
        device!(dev)
        llds[di]    = numRows[di]
        dev_row     = mod(di - 1, n_row_devs) + 1
        dev_col     = div(di - 1, n_row_devs) + 1
        row_inds    = ((dev_row-1)*row_block_size+1):min(dev_row*row_block_size, size(D, 1))
        col_inds    = ((dev_col-1)*col_block_size+1):min(dev_col*col_block_size, size(D, 2))
        if !isassigned(streams, di)
            streams[di] = CuStream()
        end
        cpu_buf = D[row_inds, col_inds]
        buffers[di] = pointer(CuArray(cpu_buf))
        synchronize()
    end
    device!(deviceIdsGrid[1])
    return buffers, llds
end

function returnBuffers(grid, n_row_devs, n_col_devs, num_devices::Int, deviceIdsGrid, streams, row_block_size, col_block_size, desc, dDs, D)
    numRows  = Vector{Int64}(undef, num_devices)
    numCols  = Vector{Int64}(undef, num_devices)
    typesize = sizeof(eltype(D))
    cudaLibMgGetLocalMatrixDimensions(desc, numRows, numCols)
    current_dev = device()
    sub_Ds = Vector{Vector}(undef, num_devices)
    for (di, dev) in enumerate(deviceIdsGrid)
        device!(dev)
        synchronize(streams[di])
        synchronize()
    end
    for (di, dev) in enumerate(deviceIdsGrid)
        device!(dev)
        dev_row = mod(di - 1, n_row_devs) + 1
        dev_col = div(di - 1, n_row_devs) + 1
        row_inds = ((dev_row-1)*row_block_size+1):min(dev_row*row_block_size, size(D, 1))
        col_inds = ((dev_col-1)*col_block_size+1):min(dev_col*col_block_size, size(D, 1))
        D[row_inds, col_inds] = collect(dDs[di])
    end
    for (di, dev) in enumerate(deviceIdsGrid)
        device!(dev)
        synchronize(streams[di])
    end
    device!(deviceIdsGrid[1])
    return D
end
# out of device move the memory myself
function mg_gemm_gpu!(transA::Char,
                  transB::Char,
                  alpha::Number,
                  A::Matrix,
                  B::Matrix,
                  beta::Number,
                  C::Matrix; devs=[0], dev_rows=1, dev_cols=1)
    device!(devs[1])
    GC.enable(false)
    grid = Ref{cudaLibMgGrid_t}(0)
    cudaLibMgCreateDeviceGrid(grid, dev_rows, dev_cols, devs, CUDALIBMG.CUDALIBMG_GRID_MAPPING_COL_MAJOR)
    cutransA = cublasop(transA)
    cutransB = cublasop(transB)
    lda = max(1, stride(A, 2)) 
    ldb = max(1, stride(B, 2))
    ldc = max(1, stride(C, 2))
    descA    = CudaLibMGDescriptor(A, grid[], rowblocks=div(size(A, 1), dev_rows), colblocks=div(size(A, 2), dev_cols))
    descB    = CudaLibMGDescriptor(B, grid[], rowblocks=div(size(B, 1), dev_rows), colblocks=div(size(B, 2), dev_cols))
    descC    = CudaLibMGDescriptor(C, grid[], rowblocks=div(size(C, 1), dev_rows), colblocks=div(size(C, 2), dev_cols))
    ndevs    = length(devs)
    streams  = Vector{CuStream}(undef, ndevs)
    dA, ldas = allocateBuffers(grid, dev_rows, dev_cols, ndevs, devs, streams, div(size(A, 1), dev_rows), div(size(A, 2), dev_cols), descA, A)
    dB, ldbs = allocateBuffers(grid, dev_rows, dev_cols, ndevs, devs, streams, div(size(B, 1), dev_rows), div(size(B, 2), dev_cols), descB, B)
    dC, ldcs = allocateBuffers(grid, dev_rows, dev_cols, ndevs, devs, streams, div(size(C, 1), dev_rows), div(size(C, 2), dev_cols), descC, C)
    lwork     = Vector{Csize_t}(undef, ndevs)
    workspace = Vector{CuPtr{Cvoid}}(undef, ndevs)
    device!(devs[1])
    alpha_arr = [alpha]
    beta_arr  = [beta]
    cublasMgGemmWorkspace(mg_handle(), cutransA, cutransB, alpha_arr, descA, dA, ldas, descB, dB, ldbs, beta_arr, descC, dC, ldcs, descC, dC, ldcs, cudaDataType(eltype(C)), workspace, lwork)
    # set up workspaces and streams
    for (di, dev) in enumerate(devs)
        device!(dev)
        buf = CUDAdrv.Mem.alloc(CUDAdrv.Mem.DeviceBuffer, lwork[di]) 
        workspace[di] = buf.ptr
        synchronize()
    end
    device!(devs[1])
    
    synchronize()
    cublasMgGemm(mg_handle(), cutransA, cutransB, alpha_arr, descA, dA, ldas, descB, dB, ldbs, beta_arr, descC, dC, ldcs, descC, dC, ldcs, cudaDataType(eltype(C)), workspace, lwork, streams)
    for (di, dev) in enumerate(devs)
        device!(dev)
        synchronize(streams[di])
        synchronize()
    end
    C = returnBuffers(grid, dev_rows, dev_cols, ndevs, devs, streams, div(size(C, 1), dev_rows), div(size(C, 2), dev_cols), descC, dC, C)
    GC.enable(true)
    return C
end

function register(A)
    GC.@preserve A begin
        buf = CUDAdrv.Mem.register(CUDAdrv.Mem.HostBuffer, pointer(A), sizeof(A), CUDAdrv.Mem.HOSTREGISTER_DEVICEMAP | CUDAdrv.Mem.HOSTREGISTER_PORTABLE)
        finalizer(A) do A
            CUDAdrv.Mem.unregister(buf)
        end
    end
    return A
end

function mg_gemm!(transA::Char,
                  transB::Char,
                  alpha::Number,
                  A::Matrix,
                  B::Matrix,
                  beta::Number,
                  C::Matrix; devs=[0])
    GC.enable(false)
    device!(devs[1])
    grid = CudaLibMGGrid(Int32(1), Int32(1), [Int32(-1)], CUDALIBMG_GRID_MAPPING_ROW_MAJOR)
    lda = max(1, stride(A, 2)) 
    ldb = max(1, stride(B, 2))
    ldc = max(1, stride(C, 2))
    cutransA = cublasop(transA)
    cutransB = cublasop(transB)
    descA    = CudaLibMGDescriptor(A, grid)
    descB    = CudaLibMGDescriptor(B, grid)
    descC    = CudaLibMGDescriptor(C, grid)
    ndevs    = length(devs)
    C_ref_arr = Vector{Ptr{Cvoid}}(undef, ndevs)
    B_ref_arr = Vector{Ptr{Cvoid}}(undef, ndevs)
    A_ref_arr = Vector{Ptr{Cvoid}}(undef, ndevs)
    lwork     = Vector{Csize_t}(undef, ndevs)
    workspace = Vector{CUDAdrv.Mem.DeviceBuffer}(undef, ndevs)
    workspace_ref = Vector{CUDAdrv.CuPtr{Cvoid}}(undef, ndevs)
    streams   = Vector{CuStream}(undef, ndevs)
    GC.@preserve descA descB descC A_ref_arr B_ref_arr C_ref_arr workspace_ref lwork A B C streams begin
        for (di, dev) in enumerate(devs)
            A_ref_arr[di] = Base.unsafe_convert(Ptr{Cvoid}, pointer(register(A)))
            B_ref_arr[di] = Base.unsafe_convert(Ptr{Cvoid}, pointer(register(B)))
            C_ref_arr[di] = Base.unsafe_convert(Ptr{Cvoid}, pointer(register(C)))
        end
        device!(devs[1])
        ldcc      = [Int64(ldc)]
        ldaa      = [Int64(lda)]
        ldbb      = [Int64(ldb)]
        cublasMgGemmWorkspace(mg_handle(), cutransA, cutransB, [alpha], descA, A_ref_arr, ldaa, descB, B_ref_arr, ldbb, [beta], descC, C_ref_arr, ldcc, descC, C_ref_arr, ldcc, cudaDataType(eltype(C)), workspace_ref, lwork)
        # set up workspaces and streams
        for (di, dev) in enumerate(devs)
            device!(dev)
            workspace[di] = CUDAdrv.Mem.alloc(CUDAdrv.Mem.DeviceBuffer, lwork[di])
            workspace_ref[di] = workspace[di].ptr 
            streams[di]   = CuDefaultStream()
            synchronize(streams[di])
            synchronize()
        end
        device!(devs[1])
        cublasMgGemm(mg_handle(), cutransA, cutransB, [alpha], descA, A_ref_arr, ldaa, descB, B_ref_arr, ldbb, [beta], descC, C_ref_arr, ldcc, descC, C_ref_arr, ldcc, cudaDataType(eltype(C)), workspace_ref, lwork, streams)
        for (di, dev) in enumerate(devs)
            device!(dev)
            synchronize(streams[di])
            synchronize()
            CUDAdrv.Mem.free(workspace[di])
        end
        device!(devs[1])
    end
    GC.enable(true)
    return C
end
