# Will be evaluated _inside_ the workspace process.

# Pluto does most things on process 1 (the server), and it uses little workspace processes to evaluate notebook code in.
# These baby processes don't import Pluto, they only import this module. Functions from this module are called by WorkspaceManager.jl, using Distributed

# So when reading this file, pretend that you are living in process 2, and you are communicating with Pluto's server, who lives in process 1.

module PlutoRunner

# import these two so that they can be imported from Main on the worker process if it launches without the stdlibs in its LOAD_PATH
import Markdown
import InteractiveUtils

using Markdown
import Markdown: html, htmlinline, LaTeX, withtag, htmlesc
import Distributed
import Base64
import FuzzyCompletions: Completion, ModuleCompletion, completions, completion_text, score
import Base: show, istextmime
import UUIDs: UUID
import Logging
import Tables

export @bind

MimedOutput = Tuple{Union{String,Vector{UInt8},Dict{Symbol,Any}},MIME}
ObjectID = typeof(objectid("hello computer"))
ObjectDimPair = Tuple{ObjectID,Int64}








###
# WORKSPACE MANAGER
###

# Will be set to the latest workspace module
"The current workspace where your variables live. See [`move_vars`](@ref)."
current_module = Main

function set_current_module(newname)
    # Revise.jl support
    if isdefined(current_module, :Revise) && 
        isdefined(current_module.Revise, :revise) && current_module.Revise.revise isa Function &&
        isdefined(current_module.Revise, :revision_queue) && current_module.Revise.revision_queue isa AbstractSet

        if !isempty(current_module.Revise.revision_queue) # to avoid the sleep(0.01) in revise()
            current_module.Revise.revise()
        end
    end
    
    global default_iocontext = IOContext(default_iocontext, :module => current_module)
    global current_module = getfield(Main, newname)
end














###
# EVALUATING NOTEBOOK CODE
###

struct ReturnProof end
const return_error = "Pluto: You can only use return inside a function."

struct Computer
    f::Function
    return_proof::ReturnProof
    input_globals::Vector{Symbol}
    output_globals::Vector{Symbol}
end

expr_hash(e::Expr) = objectid(e.head) + mapreduce(p -> objectid((p[1], expr_hash(p[2]))), +, enumerate(e.args); init=zero(ObjectID))
expr_hash(x) = objectid(x)
# TODO: clear key when a cell is deleted furever
const computers = Dict{ObjectID,Computer}()

const computer_workspace = Main


function register_computer(expr::Expr, key, input_globals::Vector{Symbol}, output_globals::Vector{Symbol})
    proof = ReturnProof()

    @gensym result
    e = Expr(:function, Expr(:call, gensym(:function_wrapped_cell), input_globals...), Expr(:block, 
        Expr(:(=), result, timed_expr(expr, proof)),
        Expr(:tuple,
            result,
            Expr(:tuple, output_globals...)
        )
    ))

    f = Core.eval(computer_workspace, e)

    computers[key] = Computer(f, proof, input_globals, output_globals)
end

valuequoted(x) = x
valuequoted(x::Symbol) = QuoteNode(x)

function compute(computer::Computer)
    # 1. get the referenced global variables
    # this might error if the global does not exist, which is exactly what we want
    input_global_values = getfield.([current_module], computer.input_globals)

    # 2. run the function
    out = Base.invokelatest(computer.f, input_global_values...)
    if out isa Tuple{Any,Tuple}
        result, output_global_values = out

        for (name, val) in zip(computer.output_globals, output_global_values)
            Core.eval(current_module, Expr(:(=), name, valuequoted(val)))
        end

        result
    else
        throw(return_error)
    end
end

"Wrap `expr` inside a timing block."
function timed_expr(expr::Expr, return_proof::Any=nothing)::Expr
    # @assert ExpressionExplorer.is_toplevel_expr(expr)

    linenumbernode = expr.args[1]
    root = expr.args[2] # pretty much equal to what `Meta.parse(cell.code)` would give

    @gensym result
    @gensym elapsed_ns
    # we don't use `quote ... end` here to avoid the LineNumberNodes that it adds (these would taint the stack trace).
    Expr(:block, 
        :(local $elapsed_ns = time_ns()),
        linenumbernode,
        :(local $result = $root),
        :($elapsed_ns = time_ns() - $elapsed_ns),
        :(($result, $elapsed_ns, $return_proof)),
    )
end

"""
Run the expression or function inside a try ... catch block, and verify its "return proof".
"""
function run_inside_trycatch(f::Union{Expr,Function}, cell_id::UUID, return_proof::ReturnProof)
    # We user return_proof to make sure the result from the `expr` went through `timed_expr`, as opposed to when `expr`
    # has an explicit `return` that causes it to jump to the result of `Core.eval` directly.

    # This seems a bit like a petty check ("I don't want people to play with Pluto!!!") but I see it more as a
    # way to protect people from finding this obscure bug in some way - DRAL

    ans, runtime = try
        local invocation = if f isa Expr
            # We eval `f` in the global scope of the workspace module:
            Core.eval(current_module, f)
        else
            # f is a function
            f()
        end

        if !isa(invocation, Tuple{Any,Number,Any}) || invocation[3] !== return_proof
            throw(return_error)
        else
            local ans, runtime, _ = invocation
            (ans, runtime)
        end
    catch ex
        bt = stacktrace(catch_backtrace())
        (CapturedException(ex, bt), missing)
    end
end


"""
Run the given expression in the current workspace module. If the third argument is `nothing`, then the expression will be `Core.eval`ed. The result and runtime are stored inside [`cell_results`](@ref) and [`cell_runtimes`](@ref).

If the third argument is a `Tuple{Set{Symbol}, Set{Symbol}}` containing the referenced and assigned variables of the expression (computed by the ExpressionExplorer), then the expression will be **wrapped inside a function**, with the references as inputs, and the assignments as outputs. Instead of running the expression directly, Pluto will call this function, with the right globals as inputs.

This function is memoized: running the same expression a second time will simply call the same generated function again. This is much faster than evaluating the expression, because the function only needs to be Julia-compiled once. See https://github.com/fonsp/Pluto.jl/pull/720
"""
function run_expression(expr::Any, cell_id::UUID, function_wrapped_info::Union{Nothing,Tuple{Set{Symbol},Set{Symbol}}}=nothing)
    cell_results[cell_id], cell_runtimes[cell_id] = if function_wrapped_info === nothing
        proof = ReturnProof()
        wrapped = timed_expr(expr, proof)
        run_inside_trycatch(wrapped, cell_id, proof)
    else
        key = expr_hash(expr)
        local computer = get(computers, key, nothing)
        if computer === nothing
            try
                computer = register_computer(expr, key, collect.(function_wrapped_info)...)
            catch e
                # @error "Failed to generate computer function" expr exception=(e,stacktrace(catch_backtrace()))
                return run_expression(expr, cell_id, nothing)
            end
        end
        ans, runtime = run_inside_trycatch(cell_id, computer.return_proof) do
            compute(computer)
        end

        # This check solves the problem of a cell like `false && variable_that_does_not_exist`. This should run without error, but will fail in our function-wrapping-magic because we get the value of `variable_that_does_not_exist` before calling the generated function.
        # The fix is to detect this situation and run the expression in the classical way.
        if (ans isa CapturedException) && (ans.ex isa UndefVarError)
            run_expression(expr, cell_id, nothing)
        else
            ans, runtime
        end
    end
end









###
# DELETING GLOBALS
###


"""
Move some of the globals over from one workspace to another. This is how Pluto "deletes" globals - it doesn't, it just executes your new code in a new module where those globals are not defined. 

Notebook code does run in `Main` - it runs in workspace modules. Every time that you run cells, a new module is created, called `Main.workspace123` with `123` an increasing number.

The trick boils down to two things:
1. When we create a new workspace module, we move over some of the global from the old workspace. (But not the ones that we want to 'delete'!)
2. If a function used to be defined, but now we want to delete it, then we go through the method table of that function and snoop out all methods that we defined by us, and not by another package. This is how we reverse extending external functions. For example, if you run a cell with `Base.sqrt(s::String) = "the square root of" * s`, and then delete that cell, then you can still call `sqrt(1)` but `sqrt("one")` will err. Cool right!
"""
function move_vars(old_workspace_name::Symbol, new_workspace_name::Symbol, vars_to_delete::Set{Symbol}, funcs_to_delete::Set{Tuple{UUID,Vector{Symbol}}}, module_imports_to_move::Set{Expr})
    old_workspace = getfield(Main, old_workspace_name)
    new_workspace = getfield(Main, new_workspace_name)

    for expr in module_imports_to_move
        try
            Core.eval(new_workspace, expr)
        catch; end # TODO catch specificallly
    end

    # TODO: delete
    Core.eval(new_workspace, :(import ..($(old_workspace_name))))

    old_names = names(old_workspace, all=true, imported=true)

    funcs_with_no_methods_left = filter(funcs_to_delete) do f
        !try_delete_toplevel_methods(old_workspace, f)
    end
    name_symbols_of_funcs_with_no_methods_left = last.(last.(funcs_with_no_methods_left))
    for symbol in old_names
        if (symbol ∈ vars_to_delete) || (symbol ∈ name_symbols_of_funcs_with_no_methods_left)
            # var will be redefined - unreference the value so that GC can snoop it

            # free memory for other variables
            # & delete methods created in the old module:
            # for example, the old module might extend an imported function:
            # `import Base: show; show(io::IO, x::Flower) = print(io, "🌷")`
            # when you delete/change this cell, you want this extension to disappear.
            if isdefined(old_workspace, symbol)
                # try_delete_toplevel_methods(old_workspace, symbol)

                try
                    # We are clearing this variable from the notebook, so we need to find it's root
                    # Just clearing out the definition in the old_module, besides giving an error (so that's what that `catch; end` is for)
                    # will not actually free it from Julia, the older module will still have a reference.
                    module_to_remove_from = which(old_workspace, symbol)
                    Core.eval(module_to_remove_from, :($(symbol) = nothing))
                catch; end # sometimes impossible, eg. when $symbol was constant
            end
        else
            # var will not be redefined in the new workspace, move it over
            if !(symbol == :eval || symbol == :include || string(symbol)[1] == '#' || startswith(string(symbol), "workspace"))
                try
                    val = getfield(old_workspace, symbol)

                    # Expose the variable in the scope of `new_workspace`
                    Core.eval(new_workspace, :(import ..($(old_workspace_name)).$(symbol)))
                catch ex
                    if !(ex isa UndefVarError)
                        @warn "Failed to move variable $(symbol) to new workspace:"
                        showerror(stderr, ex, stacktrace(catch_backtrace()))
                    end
                end
            end
        end
    end
end

"Return whether the `method` was defined inside this notebook, and not in external code."
isfromcell(method::Method, cell_id::UUID) = endswith(String(method.file), string(cell_id))

"Delete all methods of `f` that were defined in this notebook, and leave the ones defined in other packages, base, etc. ✂

Return whether the function has any methods left after deletion."
function delete_toplevel_methods(f::Function, cell_id::UUID)::Bool
    # we can delete methods of functions!
    # instead of deleting all methods, we only delete methods that were defined in this notebook. This is necessary when the notebook code extends a function from remote code
    methods_table = typeof(f).name.mt
    deleted_sigs = Set{Type}()
    Base.visit(methods_table) do method # iterates through all methods of `f`, including overridden ones
        if isfromcell(method, cell_id) && getfield(method, deleted_world) == alive_world_val
            Base.delete_method(method)
            push!(deleted_sigs, method.sig)
        end
    end

    # if `f` is an extension to an external function, and we defined a method that overrides a method, for example,
    # we define `Base.isodd(n::Integer) = rand(Bool)`, which overrides the existing method `Base.isodd(n::Integer)`
    # calling `Base.delete_method` on this method won't bring back the old method, because our new method still exists in the method table, and it has a world age which is newer than the original. (our method has a deleted_world value set, which disables it)
    # 
    # To solve this, we iterate again, and _re-enable any methods that were hidden in this way_, by adding them again to the method table with an even newer`primary_world`.
    if !isempty(deleted_sigs)
        to_insert = Method[]
        Base.visit(methods_table) do method
            if !isfromcell(method, cell_id) && method.sig ∈ deleted_sigs
                push!(to_insert, method)
            end
        end
        # separate loop to avoid visiting the recently added method
        for method in Iterators.reverse(to_insert)
            setfield!(method, primary_world, one(typeof(alive_world_val))) # `1` will tell Julia to increment the world counter and set it as this function's world
            ccall(:jl_method_table_insert, Cvoid, (Any, Any, Ptr{Cvoid}), methods_table, method, C_NULL) # i dont like doing this either!
        end
    end
    return !isempty(methods(f).ms)
end

# function try_delete_toplevel_methods(workspace::Module, name::Symbol)
#     try_delete_toplevel_methods(workspace, [name])
# end

function try_delete_toplevel_methods(workspace::Module, (cell_id, name_parts)::Tuple{UUID,Vector{Symbol}})::Bool
    try
        val = workspace
        for name in name_parts
            val = getfield(val, name)
        end
        try
            (val isa Function) && delete_toplevel_methods(val, cell_id)
        catch ex
            @warn "Failed to delete methods for $(name_parts)"
            showerror(stderr, ex, stacktrace(catch_backtrace()))
            false
        end
    catch
        false
    end
end

# these deal with some inconsistencies in Julia's internal (undocumented!) variable names
const primary_world = filter(in(fieldnames(Method)), [:primary_world, :min_world]) |> first # Julia v1.3 and v1.0 resp.
const deleted_world = filter(in(fieldnames(Method)), [:deleted_world, :max_world]) |> first # Julia v1.3 and v1.0 resp.
const alive_world_val = getfield(methods(Base.sqrt).ms[1], deleted_world) # typemax(UInt) in Julia v1.3, Int(-1) in Julia 1.0


















###
# FORMATTING
###


# TODO: clear key when a cell is deleted furever
const cell_results = Dict{UUID,Any}()
const cell_runtimes = Dict{UUID,Union{Missing,UInt64}}()

const tree_display_limit = 30
const tree_display_limit_increase = 40
const table_row_display_limit = 10
const table_row_display_limit_increase = 60
const table_column_display_limit = 8
const table_column_display_limit_increase = 30

const tree_display_extra_items = Dict{UUID,Dict{ObjectDimPair,Int64}}()

function formatted_result_of(id::UUID, ends_with_semicolon::Bool, showmore::Union{ObjectDimPair,Nothing}=nothing)::NamedTuple{(:output_formatted, :errored, :interrupted, :runtime),Tuple{MimedOutput,Bool,Bool,Union{UInt64,Missing}}}
    extra_items = if showmore === nothing
        tree_display_extra_items[id] = Dict{ObjectDimPair,Int64}()
    else
        old = get!(() -> Dict{ObjectDimPair,Int64}(), tree_display_extra_items, id)
        old[showmore] = get(old, showmore, 0) + 1
        old
    end

    ans = cell_results[id]
    errored = ans isa CapturedException

    output_formatted = (!ends_with_semicolon || errored) ? format_output(ans; context=:extra_items=>extra_items) : ("", MIME"text/plain"())
    (output_formatted = output_formatted, errored = errored, interrupted = false, runtime = get(cell_runtimes, id, missing))
end


"Because even showerror can error... 👀"
function try_showerror(io::IO, e, args...)
    try
        showerror(io, e, args...)
    catch show_ex
        print(io, "\nFailed to show error:\n\n")
        try_showerror(io, show_ex, stacktrace(catch_backtrace()))
    end
end

# We add a method for the Markdown -> HTML conversion that takes a LaTeX chunk from the Markdown tree and adds our custom span
function htmlinline(io::IO, x::LaTeX)
    withtag(io, :span, :class => "tex") do
        print(io, '$')
        htmlesc(io, x.formula)
        print(io, '$')
    end
end

# this one for block equations: (double $$)
function html(io::IO, x::LaTeX)
    withtag(io, :p, :class => "tex") do
        print(io, '$', '$')
        htmlesc(io, x.formula)
        print(io, '$', '$')
    end
end

# because i like that
Base.IOContext(io::IOContext, ::Nothing) = io

"The `IOContext` used for converting arbitrary objects to pretty strings."
default_iocontext = IOContext(devnull, :color => false, :limit => true, :displaysize => (18, 88))

const imagemimes = [MIME"image/svg+xml"(), MIME"image/png"(), MIME"image/jpg"(), MIME"image/jpeg"(), MIME"image/bmp"(), MIME"image/gif"()]
# in descending order of coolness
# text/plain always matches - almost always
"""
The MIMEs that Pluto supports, in order of how much I like them. 

`text/plain` should always match - the difference between `show(::IO, ::MIME"text/plain", x)` and `show(::IO, x)` is an unsolved mystery.
"""
const allmimes = [MIME"application/vnd.pluto.table+object"(); MIME"text/html"(); imagemimes; MIME"application/vnd.pluto.tree+object"(); MIME"text/latex"(); MIME"text/plain"()]


"""
Format `val` using the richest possible output, return formatted string and used MIME type.

See [`allmimes`](@ref) for the ordered list of supported MIME types.
"""
function format_output_default(@nospecialize(val); context=nothing)::MimedOutput
    try
        new_iocontext = IOContext(default_iocontext, context)
        io_sprinted, (value, mime) = sprint_withreturned(show_richest, val; context=new_iocontext)
        if value === nothing
            if mime ∈ imagemimes
                io_sprinted, mime
            else
                String(io_sprinted), mime
            end
        else
            (value, mime)::MimedOutput
        end
    catch ex
        title = ErrorException("Failed to show value: \n" * sprint(try_showerror, ex))
        bt = stacktrace(catch_backtrace())
        format_output(CapturedException(title, bt))::MimedOutput
    end
end

format_output(x; context=nothing)::MimedOutput = format_output_default(x; context=context)

format_output(::Nothing; context=nothing)::MimedOutput = "", MIME"text/plain"()

function format_output(val::CapturedException; context=nothing)::MimedOutput
    ## We hide the part of the stacktrace that belongs to Pluto's evalling of user code.
    stack = [s for (s, _) in val.processed_bt]

    function_wrap_index = findfirst(f -> occursin("function_wrapped_cell", String(f.func)), stack)

    if function_wrap_index === nothing
        for _ in 1:2
            until = findfirst(b -> b.func == :eval, reverse(stack))
            stack = until === nothing ? stack : stack[1:end - until]
        end
    else
        stack = stack[1:function_wrap_index]
    end

    pretty = map(stack) do s
        Dict(
            :call => pretty_stackcall(s, s.linfo),
            :inlined => s.inlined,
            :file => basename(String(s.file)),
            :line => s.line,
        )
    end
    Dict{Symbol,Any}(:msg => sprint(try_showerror, val.ex), :stacktrace => pretty), MIME"application/vnd.pluto.stacktrace+object"()
end

# from the Julia source code:
function pretty_stackcall(frame::Base.StackFrame, linfo::Nothing)::String
    if frame.func isa Symbol
        if occursin("function_wrapped_cell", String(frame.func))
            "top-level scope"
        else
            String(frame.func)
        end
    else
        repr(frame.func)
    end
end

function pretty_stackcall(frame::Base.StackFrame, linfo::Core.CodeInfo)
    "top-level scope"
end

function pretty_stackcall(frame::Base.StackFrame, linfo::Core.MethodInstance)
    if linfo.def isa Method
        sprint(Base.show_tuple_as_call, linfo.def.name, linfo.specTypes)
    else
        sprint(Base.show, linfo)
    end
end

"Like `Base.sprint`, but return a `(String, Any)` tuple containing function output as the second entry."
function sprint_withreturned(f::Function, args...; context=nothing, sizehint::Integer=0)
    buffer = IOBuffer(sizehint=sizehint)
    val = f(IOContext(buffer, context), args...)
    resize!(buffer.data, buffer.size), val
end

"Super important thing don't change."
struct 🥔 end
const struct_showmethod = which(show, (IO, 🥔))
const struct_showmethod_mime = which(show, (IO, MIME"text/plain", 🥔))

function use_tree_viewer_for_struct(@nospecialize(x::T))::Bool where T
    # types that have no specialized show methods (their fallback is text/plain) are displayed using Pluto's interactive tree viewer. 
    # this is how we check whether this display method is appropriate:
    isstruct = try
        T isa DataType &&
        # there are two ways to override the plaintext show method: 
        which(show, (IO, MIME"text/plain", T)) === struct_showmethod_mime &&
        which(show, (IO, T)) === struct_showmethod
    catch
        false
    end

    isstruct && let
        # from julia source code, dont know why
        nf = nfields(x)
        nb = sizeof(x)
        nf != 0 || nb == 0
    end
end

"""
Like two-argument `Base.show`, except:
1. the richest MIME type available to Pluto will be used
2. the used MIME type is returned as second element
3. if the first returned element is `nothing`, then we wrote our data to `io`. If it is something else (a Dict), then that object will be the cell's output, instead of the buffered io stream. This allows us to output rich objects to the frontend that are not necessarily strings or byte streams
"""
function show_richest(io::IO, @nospecialize(x))::Tuple{<:Any,MIME}
    mime = Iterators.filter(m -> pluto_showable(m, x), allmimes) |> first
    
    if mime isa MIME"text/plain" && use_tree_viewer_for_struct(x)
        tree_data(x, io), MIME"application/vnd.pluto.tree+object"()
    elseif mime isa MIME"application/vnd.pluto.tree+object"
        tree_data(x, IOContext(io, :compact => true)), mime
    elseif mime isa MIME"application/vnd.pluto.table+object"
        table_data(x, IOContext(io, :compact => true)), mime
    elseif mime ∈ imagemimes
        show(io, mime, x)
        nothing, mime
    elseif mime isa MIME"text/latex"
        # Wrapping with `\text{}` allows for LaTeXStrings with mixed text/math
        texed = repr(mime, x)
        html(io, Markdown.LaTeX("\\text{$texed}"))
        nothing, MIME"text/html"()
    else
        # the classic:
        show(io, mime, x)
        nothing, mime
    end
end

# we write our own function instead of extending Base.showable with our new MIME because:
# we need the method Base.showable(::MIME"asdfasdf", ::Any) = Tables.rowaccess(x)
# but overload ::MIME{"asdf"}, ::Any will cause ambiguity errors in other packages that write a method like:
# Baee.showable(m::MIME, x::Plots.Plot)
# because MIME is less specific than MIME"asdff", but Plots.PLot is more specific than Any.
pluto_showable(m::MIME, @nospecialize(x))::Bool = Base.invokelatest(showable, m, x)

###
# TREE VIEWER
###


# We invent our own MIME _because we can_ but don't use it somewhere else because it might change :)
pluto_showable(::MIME"application/vnd.pluto.tree+object", ::AbstractArray{<:Any,1}) = true
pluto_showable(::MIME"application/vnd.pluto.tree+object", ::AbstractDict{<:Any,<:Any}) = true
pluto_showable(::MIME"application/vnd.pluto.tree+object", ::Tuple) = true
pluto_showable(::MIME"application/vnd.pluto.tree+object", ::NamedTuple) = true
pluto_showable(::MIME"application/vnd.pluto.tree+object", ::Pair) = true

pluto_showable(::MIME"application/vnd.pluto.tree+object", ::AbstractRange) = false

pluto_showable(::MIME"application/vnd.pluto.tree+object", ::Any) = false


pluto_showable(::MIME"application/vnd.pluto.table+object", x::Any) = try Tables.rowaccess(x)::Bool catch; false end
pluto_showable(::MIME"application/vnd.pluto.table+object", t::Type) = false
pluto_showable(::MIME"application/vnd.pluto.table+object", t::AbstractVector{<:NamedTuple}) = false


# in the next functions you see a `context` argument
# this is really only used for the circular reference tracking

function tree_data_array_elements(@nospecialize(x::AbstractArray{<:Any,1}), indices::AbstractVector{I}, context::IOContext)::Vector{Tuple{I,Any}} where {I<:Integer}
    Tuple{I,Any}[
        if isassigned(x, i)
            i, format_output_default(x[i]; context=context)
        else
            i, format_output_default(Text(Base.undef_ref_str); context=context)
        end
        for i in indices
    ] |> collect
end

function array_prefix(@nospecialize(x::Array{<:Any,1}))::String
    string(eltype(x))
end
function array_prefix(@nospecialize(x))::String
    original = sprint(Base.showarg, x, false)
    lstrip(original, ':') * ": "
end

function get_my_display_limit(@nospecialize(x), dim::Integer, context::IOContext, a::Integer, b::Integer)::Int # needs to be system-dependent Int because it is used as array index
    a + let
        d = get(context, :extra_items, nothing)
        if d === nothing
            0
        else
            b * get(d, (objectid(x), dim), 0)
        end
    end
end

function tree_data(@nospecialize(x::AbstractArray{<:Any,1}), context::IOContext)
    indices = eachindex(x)
    my_limit = get_my_display_limit(x, 1, context, tree_display_limit, tree_display_limit_increase)

    # additional 5 so that we don't cut off 1 or 2 itmes - that's silly
    elements = if length(x) <= my_limit + 5
        tree_data_array_elements(x, indices, context)
    else
        firsti = firstindex(x)
        from_end = my_limit > 20 ? 10 : 1
        Any[
            tree_data_array_elements(x, indices[firsti:firsti-1+my_limit-from_end], context)...,
            "more",
            tree_data_array_elements(x, indices[end+1-from_end:end], context)...,
        ]
    end
    
    Dict{Symbol,Any}(
        :prefix => array_prefix(x),
        :objectid => string(objectid(x), base=16),
        :type => :Array,
        :elements => elements
    )
end

function tree_data(@nospecialize(x::Tuple), context::IOContext)
    Dict{Symbol,Any}(
        :objectid => string(objectid(x), base=16),
        :type => :Tuple,
        :elements => collect(enumerate(format_output_default.(x; context=context))),
    )
end

function tree_data(@nospecialize(x::AbstractDict{<:Any,<:Any}), context::IOContext)
    elements = []

    my_limit = get_my_display_limit(x, 1, context, tree_display_limit, tree_display_limit_increase)
    row_index = 1
    for pair in x
        k, v = pair
        push!(elements, (format_output_default(k; context=context), format_output_default(v; context=context)))
        if row_index == my_limit
            push!(elements, "more")
            break
        end
        row_index += 1
    end
    
    Dict{Symbol,Any}(
        :prefix => string(typeof(x) |> trynameof),
        :objectid => string(objectid(x), base=16),
        :type => :Dict,
        :elements => elements
    )
end

function tree_data_nt_row(pair::Tuple, context::IOContext)
    # this is an entry of a NamedTuple, the first element of the Tuple is a Symbol, which we want to print as `x` instead of `:x`
    k, element = pair
    string(k), format_output_default(element; context=context)
end


function tree_data(@nospecialize(x::NamedTuple), context::IOContext)
    Dict{Symbol,Any}(
        :objectid => string(objectid(x), base=16),
        :type => :NamedTuple,
        :elements => tree_data_nt_row.(zip(eachindex(x), x), (context,))
    )
end

function tree_data(@nospecialize(x::Pair), context::IOContext)
    k, v = x
    Dict{Symbol,Any}(
        :objectid => string(objectid(x), base=16),
        :type => :Pair,
        :key_value => (format_output_default(k; context=context), format_output_default(v; context=context)),
    )
end

# Based on Julia source code but without writing to IO
function tree_data(@nospecialize(x::Any), context::IOContext)
    t = typeof(x)
    nf = nfields(x)
    nb = sizeof(x)
    
    if Base.show_circular(context, x)
        Dict{Symbol,Any}(
            :objectid => string(objectid(x), base=16),
            :type => :circular,
        )
    else
        recur_io = IOContext(context, Pair{Symbol,Any}(:SHOWN_SET, x),
                                Pair{Symbol,Any}(:typeinfo, Any))
        
        elements = map(1:nf) do i
            f = fieldname(t, i)
            if !isdefined(x, f)
                Base.undef_ref_str
                f, format_output_default(Text(Base.undef_ref_str); context=recur_io)
            else
                f, format_output_default(getfield(x, i); context=recur_io)
            end
        end
    
        Dict{Symbol,Any}(
            :prefix => repr(t; context=context),
            :objectid => string(objectid(x), base=16),
            :type => :struct,
            :elements => elements,
        )
    end

end

trynameof(x::DataType) = nameof(x)
trynameof(x::Any) = Symbol()

###
# TABLE VIEWER
##

function maptruncated(f::Function, xs, filler, limit; truncate=true)
    if truncate
        result = Any[
            # not xs[1:limit] because of https://github.com/JuliaLang/julia/issues/38364
            f(xs[i]) for i in 1:limit
        ]
        push!(result, filler)
        result
    else
        Any[f(x) for x in xs]
    end
end

function table_data(x::Any, io::IOContext)
    rows = Tables.rows(x)

    my_row_limit = get_my_display_limit(x, 1, io, table_row_display_limit, table_row_display_limit_increase)

    # TODO: the commented line adds support for lazy loading columns, but it uses the same extra_items counter as the rows. So clicking More Rows will also give more columns, and vice versa, which isn't ideal. To fix, maybe use (objectid,dimension) as index instead of (objectid)?

    my_column_limit = get_my_display_limit(x, 2, io, table_column_display_limit, table_column_display_limit_increase)
    # my_column_limit = table_column_display_limit

    # additional 5 so that we don't cut off 1 or 2 itmes - that's silly
    truncate_rows = my_row_limit + 5 < length(rows)
    truncate_columns = if isempty(rows)
        false
    else
        my_column_limit + 5 < length(first(rows))
    end

    row_data_for(row) = maptruncated(row, "more", my_column_limit; truncate=truncate_columns) do el
        format_output_default(el; context=io)
    end

    # ugliest code in Pluto:

    # not a map(row) because it needs to be a Vector
    # not enumerate(rows) because of some silliness
    # not rows[i] because `getindex` is not guaranteed to exist
    L = truncate_rows ? my_row_limit : length(rows)
    row_data = Array{Any,1}(undef, L)
    for (i, row) in zip(1:L,rows)
        row_data[i] = (i, row_data_for(row))
    end

    if truncate_rows
        push!(row_data, "more")
        if applicable(lastindex, rows)
            push!(row_data, (length(rows), row_data_for(last(rows))))
        end
    end
    
    # TODO: render entire schema by default?

    schema = Tables.schema(rows)
    schema_data = schema === nothing ? nothing : Dict{Symbol,Any}(
        :names => maptruncated(string, schema.names, "more", my_column_limit; truncate=truncate_columns),
        :types => String.(maptruncated(trynameof, schema.types, "more", my_column_limit; truncate=truncate_columns)),
    )

    Dict{Symbol,Any}(
        :objectid => string(objectid(x), base=16),
        :schema => schema_data,
        :rows => row_data,
    )
end


















###
# REPL THINGS
###

function basic_completion_priority((s, description, exported))
	c = first(s)
	if islowercase(c)
		1 - 10exported
	elseif isuppercase(c)
		2 - 10exported
	else
		3 - 10exported
	end
end

completed_object_description(x::Function) = "Function"
completed_object_description(x::Number) = "Number"
completed_object_description(x::AbstractString) = "String"
completed_object_description(x::Module) = "Module"
completed_object_description(x::AbstractArray) = "Array"
completed_object_description(x::Any) = "Any"

completion_description(c::ModuleCompletion) = try
    completed_object_description(getfield(c.parent, Symbol(c.mod)))
catch
    nothing
end
completion_description(::Completion) = nothing

function completions_exported(cs::Vector{<:Completion})
    completed_modules = Set(c.parent for c in cs if c isa ModuleCompletion)
    completed_modules_exports = Dict(m => string.(names(m, all=false, imported=true)) for m in completed_modules)

    map(cs) do c
        if c isa ModuleCompletion
            c.mod ∈ completed_modules_exports[c.parent]
        else
            true
        end
    end
end

"You say Linear, I say Algebra!"
function completion_fetcher(query, pos, workspace::Module=current_module)
    results, loc, found = completions(query, pos, workspace)
    if endswith(query, '.')
        # we are autocompleting a module, and we want to see its fields alphabetically
        sort!(results; by=(r -> completion_text(r)))
    else
        isenough(x) = x ≥ 0
        filter!(isenough ∘ score, results) # too many candiates otherwise
    end

    texts = completion_text.(results)
    descriptions = completion_description.(results)
    exported = completions_exported(results)

    smooshed_together = collect(zip(texts, descriptions, exported))

    p = if endswith(query, '.')
        sortperm(smooshed_together; alg=MergeSort, by=basic_completion_priority)
    else
        # we give 3 extra score points to exported fields
        scores = score.(results)
        sortperm(scores .+ 3.0 * exported; alg=MergeSort, rev=true)
    end

    final = smooshed_together[p]
    (final, loc, found)
end

"""
    is_pure_expression(expression::ReturnValue{Meta.parse})
Checks if an expression is approximately pure.
Not sure if the type signature conveys it, but this take anything that is returned from `Meta.parse`.
It obviously does not actually check if something is strictly pure, as `getproperty()` could be extended,
and suddenly there can be side effects everywhere. This is just an approximation.
"""
function is_pure_expression(expr::Expr)
    if expr.head == :. || expr.head === :curly || expr.head === :ref
        all((is_pure_expression(x) for x in expr.args))
    else
        false
    end
end
is_pure_expression(s::Symbol) = true
is_pure_expression(q::QuoteNode) = true
is_pure_expression(q::Number) = true
is_pure_expression(q::String) = true
is_pure_expression(x) = false # Better safe than sorry I guess

# Based on /base/docs/bindings.jl from Julia source code
function binding_from(x::Expr, workspace::Module=current_module)
    if x.head == :macrocall
        macro_name = x.args[1]
        if is_pure_expression(macro_name)
            Core.eval(workspace, macro_name)
        else
            error("Couldn't infer `$x` for Live Docs.")
        end
    elseif is_pure_expression(x)
        Core.eval(workspace, x)
    else
        error("Couldn't infer `$x` for Live Docs.")
    end
end
binding_from(s::Symbol, workspace::Module=current_module) = Core.eval(workspace, s)
binding_from(r::GlobalRef, workspace::Module=current_module) = Docs.Binding(r.mod, r.name)
binding_from(other, workspace::Module=current_module) = error("Invalid @var syntax `$other`.")

"You say doc_fetch, I say You say doc_fetch, I say You say doc_fetch, I say You say doc_fetch, I say ...!!!!"
function doc_fetcher(query, workspace::Module=current_module)
    try
        value = binding_from(Meta.parse(query), workspace)
        (repr(MIME"text/html"(), Docs.doc(value)), :👍)
    catch ex
        (nothing, :👎)
    end
end


















###
# BONDS
###

"""
_“The name is Bond, James Bond.”_

Wraps around an `element` and not much else. When you `show` a `Bond` with the `text/html` MIME type, you will get:

```html
<bond def="\$(bond.defines)">
\$(repr(MIME"text/html"(), bond.element))
</bond>
```

For example, `Bond(html"<input type=range>", :x)` becomes:

```html
<bond def="x">
<input type=range>
</bond>
```

The actual reactive-interactive functionality is not done in Julia - it is handled by the Pluto front-end (JavaScript), which searches cell output for `<bond>` elements, and attaches event listeners to them. Put on your slippers and have a look at the JS code to learn more.
"""
struct Bond
    element::Any
    defines::Symbol
    Bond(element, defines::Symbol) = showable(MIME"text/html"(), element) ? new(element, defines) : error("""Can only bind to html-showable objects, ie types T for which show(io, ::MIME"text/html", x::T) is defined.""")
end

import Base: show
function show(io::IO, ::MIME"text/html", bond::Bond)
    withtag(io, :bond, :def => bond.defines) do 
        show(io, MIME"text/html"(), bond.element)
    end
end

"""
    `@bind symbol element`

Return the HTML `element`, and use its latest JavaScript value as the definition of `symbol`.

# Example

```julia
@bind x html"<input type=range>"
```
and in another cell:
```julia
x^2
```

The first cell will show a slider as the cell's output, ranging from 0 until 100.
The second cell will show the square of `x`, and is updated in real-time as the slider is moved.
"""
macro bind(def, element)
	if def isa Symbol
		quote
			local el = $(esc(element))
            global $(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : missing
			PlutoRunner.Bond(el, $(Meta.quot(def)))
		end
	else
		:(throw(ArgumentError("""\nMacro example usage: \n\n\t@bind my_number html"<input type='range'>"\n\n""")))
	end
end

"""
Will be inserted in saved notebooks that use the @bind macro, make sure that they still contain legal syntax when executed as a vanilla Julia script. Overloading `Base.get` for custom UI objects gives bound variables a sensible value.
"""
const fake_bind = """macro bind(def, element)
    quote
        local el = \$(esc(element))
        global \$(esc(def)) = Core.applicable(Base.get, el) ? Base.get(el) : missing
        el
    end
end"""


















###
# LOGGING
###

const log_channel = Channel{Any}(10)
const old_logger = Ref{Any}(nothing)

struct PlutoLogger <: Logging.AbstractLogger
    stream
end

function Logging.shouldlog(::PlutoLogger, level, _module, _...)
    # Accept logs
    # - From the user's workspace module
    # - Info level and above for other modules
    _module === current_module || convert(Logging.LogLevel, level) >= Logging.Info
end
Logging.min_enabled_level(::PlutoLogger) = Logging.Debug
Logging.catch_exceptions(::PlutoLogger) = false
function Logging.handle_message(::PlutoLogger, level, msg, _module, group, id, file, line; kwargs...)
    try
        put!(log_channel, (level=string(level),
            msg=(msg isa String) ? msg : repr(msg),
            group=group,
            # id=id,
            file=file,
            line=line,
            kwargs=Dict((k=>repr(v) for (k, v) in kwargs)...),))
        # also print to console
        Logging.handle_message(old_logger[], level, msg, _module, group, id, file, line; kwargs...)
    catch e
        println(stderr, "Failed to relay log from PlutoRunner")
        showerror(stderr, e, stacktrace(catch_backtrace()))
    end
end

# we put this in __init__ to fix a world age problem
function __init__()
    if Distributed.myid() != 1
        old_logger[] = Logging.global_logger()
        Logging.global_logger(PlutoLogger(nothing))
    end
end

end
