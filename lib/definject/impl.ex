defmodule Definject.Impl do
  @moduledoc false
  @uninjectable quote(do: [:erlang])
  @env_modifiers [:import, :require, :use]

  def inject_function(%{head: head, body: body, env: %Macro.Env{} = env}) do
    with {:ok, ^body} <- body |> check_no_modifier_recursively(),
         {:ok, expanded_body} <- body |> expand_recursively(env),
         {:ok, {injected_body, captures}} <- expanded_body |> inject_recursively() do
      injected_head = head_with_deps(head)

      quote do
        def unquote(injected_head) do
          Definject.Check.validate_deps(unquote(captures) |> IO.inspect(), deps)

          unquote(injected_body)
        end
      end
    else
      {:error, special_form} when special_form in @env_modifiers ->
        quote do
          raise "Cannot import/require/use inside definject. Move it to module level."
        end
    end
  end

  def check_no_modifier_recursively(ast) do
    ast
    |> Macro.prewalk(:ok, fn
      ast, {:error, reason} ->
        {ast, {:error, reason}}

      {special_form, _, _} = ast, :ok when special_form in @env_modifiers ->
        {ast, {:error, special_form}}

      ast, :ok ->
        {ast, :ok}
    end)
    |> convert_walk_result()
  end

  def expand_recursively(ast, env) do
    ast
    |> Macro.prewalk(:ok, fn
      ast, {:error, reason} ->
        {ast, {:error, reason}}

      {:@, _, _} = ast, :ok ->
        {ast, :ok}

      ast, :ok ->
        {Macro.expand(ast, env), :ok}
    end)
    |> convert_walk_result()
  end

  defp convert_walk_result({expanded_ast, :ok}), do: {:ok, expanded_ast}
  defp convert_walk_result({_, {:error, reason}}), do: {:error, reason}

  # Don't use Macro.prewalk to bypass `&`,
  # otherwise it visits `A.b` in `&A.b/1`.
  def inject_recursively({:&, _, _} = ast) do
    {:ok, {ast, []}}
  end

  def inject_recursively({{:., _dot_ctx, [remote_mod, name]}, _call_ctx, args})
      when remote_mod not in @uninjectable and is_atom(name) and is_list(args) do
    case args |> inject_recursively() do
      {:ok, {injected_args, captures}} ->
        capture = function_capture_ast(remote_mod, name, Enum.count(args))

        injected_call =
          quote do
            (deps[unquote(capture)] || unquote(capture)).(unquote_splicing(injected_args))
          end

        {:ok, {injected_call, [capture | captures]}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def inject_recursively({func, ctx, args}) when is_list(args) do
    with {:ok, {injected_args, captures}} <- inject_recursively(args) do
      {:ok, {{func, ctx, injected_args}, captures}}
    end
  end

  def inject_recursively(asts) when is_list(asts) do
    asts
    |> Enum.reverse()
    |> Enum.reduce_while({:ok, {[], []}}, fn ast, {:ok, {injected_asts, captures}} ->
      case inject_recursively(ast) do
        {:ok, {injected_ast, new_captures}} ->
          {:cont, {:ok, {[injected_ast | injected_asts], new_captures ++ captures}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  def inject_recursively(ast) do
    {:ok, {ast, []}}
  end

  def head_with_deps({:when, when_ctx, [call_head, when_cond]}) do
    head = head_with_deps(call_head)
    {:when, when_ctx, [head, when_cond]}
  end

  def head_with_deps({name, meta, context}) when not is_list(context) do
    # Normalize function head.
    # def some do: nil end   ->   def some(), do: nil end
    head_with_deps({name, meta, []})
  end

  def head_with_deps({name, meta, params}) when is_list(params) do
    deps =
      quote do
        %{} = deps \\ %{}
      end

    {name, meta, params ++ [deps]}
  end

  # For mock/1

  def surround_by_fn({{:&, _, [capture]}, v}) do
    {:/, _, [mf, a]} = capture
    {mf, _, []} = mf
    {:., _, [m, f]} = mf

    capture = function_capture_ast(m, f, a)
    const_fn = {:fn, [], [{:->, [], [Macro.generate_arguments(a, __MODULE__), v]}]}

    {capture, const_fn}
  end

  def surround_by_fn({:strict, _} = orig) do
    orig
  end

  defp function_capture_ast(remote_mod, name, arity) do
    mf = {{:., [], [remote_mod, name]}, [], []}
    mfa = {:/, [], [mf, arity]}
    {:&, [], [mfa]}
  end
end
