module CodeInfoTools

using Core: CodeInfo, Slot
using Core.Compiler: NewSSAValue, renumber_ir_elements!

import Base: iterate, push!, insert!, replace!, display

resolve(x) = x
resolve(x::GlobalRef) = getproperty(x.mod, x.name)
resolve(x::Expr) = Expr(x.head, map(resolve, x.args)...)
resolve(x::Core.NewvarNode) = x
resolve(x::Core.GotoIfNot) = Core.GotoIfNot(resolve(x.cond), resolve(x.dest))
resolve(x::Core.SlotNumber) = x
resolve(x::Core.ReturnNode) = Core.ReturnNode(resolve(x.val))

#####
##### Builder
#####

struct Builder
    ref::CodeInfo
    code::Vector{Any}
    nargs::Int32
    codelocs::Vector{Int32}
    newslots::Dict{Int,Symbol}
    slotnames::Vector{Symbol}
    changemap::Vector{Int}
    slotmap::Vector{Int}

    function Builder(ci::CodeInfo, nargs::Int)
        code = []
        codelocs = Int32[]
        newslots = Dict{Int,Symbol}()
        slotnames = copy(ci.slotnames)
        changemap = fill(0, length(ci.code))
        slotmap = fill(0, length(ci.slotnames))
        b = new(ci, code, nargs + 1, codelocs, newslots, slotnames, changemap, slotmap)
        prepare_builder!(b)
        return b
    end
end

function Base.getindex(b::Builder, i::Int)
    @assert(i <= length(b.code))
    return getindex(b.code, i)
end

function iterate(b::Builder, (ks, i)=(1:length(b.code), 1))
    i <= length(ks) || return
    return (ks[i] => b[i], (ks, i + 1))
end

function code_info(f, tt; generated=true, debuginfo=:default)
    ir = code_lowered(f, tt; generated=generated, debuginfo=:default)
    isempty(ir) && return nothing
    return ir[1], Builder(ir[1], length(tt.parameters))
end

slot(b::Builder, name::Symbol) = Core.SlotNumber(findfirst(isequal(name), ci.slotnames))

function insert!(b::Builder, v::Int, slot::Core.SlotNumber)
    ci.newslots[v] = slot.id
    insert!(ci.slotnames, v, slot.id)
    prev = length(filter(x -> x < v, keys(ci.newslots)))
    for k in (v - prev):length(ci.slotmap)
        ci.slotmap[k] += 1
    end
    return ci
end

function push!(b::Builder, stmt, codeloc::Int32=Int32(1))
    push!(b.code, stmt)
    push!(b.codelocs, codeloc)
    return b
end

function insert!(b::Builder, v::Int, stmt)
    push!(b, stmt, b.ref.codelocs[v])
    b.changemap[v] += 1
    return NewSSAValue(length(b.code))
end

function Base.replace!(b::Builder, v::Int, stmt)
    @assert(v <= length(b.ref.codelocs))
    b.code[v] = stmt
    return NewSSAValue(v + 1)
end

function update_slots(e, slotmap)
    e isa Core.SlotNumber && return Core.SlotNumber(e.id + slotmap[e.id])
    e isa Expr && return Expr(e.head, map(x -> update_slots(x, slotmap), e.args)...)
    e isa Core.NewvarNode &&
        return Core.NewvarNode(Core.SlotNumber(e.slot.id + slotmap[e.slot.id]))
    return e
end

function prepare_builder!(b::Builder)
    for (v, st) in enumerate(b.ref.code)
        push!(b, resolve(st))
    end
    return b
end

function _replace_new_ssavalue(e)
    e isa NewSSAValue && return SSAValue(e.id)
    e isa Expr && return Expr(e.head, map(_replace_new_ssavalue, e.args)...)
    if e isa Core.GotoIfNot
        cond = e.cond
        if cond isa NewSSAValue
            cond = SSAValue(cond.id)
        end
        return Core.GotoIfNot(cond, e.dest)
    end
    e isa Core.ReturnNode &&
        isdefined(e, :val) &&
        isa(e.val, NewSSAValue) &&
        return Core.ReturnNode(SSAValue(e.val.id))
    return e
end

function replace_new_ssavalue(code::Vector)
    return [_replace_new_ssavalue(code[idx]) for idx in 1:length(code)]
end

function finish(b::Builder)
    renumber_ir_elements!(b.code, b.changemap)
    code = replace_new_ssavalue(b.code)
    new_ci = copy(b.ref)
    new_ci.code = code
    new_ci.codelocs = b.codelocs
    new_ci.slotnames = b.slotnames
    new_ci.slotflags = [0x00 for _ in new_ci.slotnames]
    new_ci.inferred = false
    new_ci.inlineable = true
    new_ci.ssavaluetypes = length(b.code)
    return new_ci
end

Base.display(b::Builder) = display(finish(b))

#####
##### Exports
#####

export code_info, Builder, finish

end # module
