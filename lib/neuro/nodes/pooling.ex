defmodule Neuro.Nodes.Pooling do
  alias Neuro.Nodes.Base
  alias Neuro.Nodes.Convolution
  use Base

  def __batch__(%{assigns: %{back_propagation: true, vars: vars}}) do
    [{"back", vars.block, vars.grid, []}]
  end
  def __batch__(%{assigns: %{vars: vars}}) do
    [{"inference", vars.block, vars.grid, []}]
  end

  def __ptx__(%{assings: %{back_propagation: true}}) do
    back_ptx()
  end
  def __ptx__(_node) do
    inference_ptx()
  end

  defp inference_ptx() do
    """
    .version 5.0
    .target sm_30
    .address_size 64

    <%= defkernel ctx, "inference" do %>
      .reg .u64   %cd<4>, %tidz;
      .reg .u32   %tidx, %tidy;
      .reg .<%= var(ctx, :f) %> %f<3>;
      .reg .pred  p;
      .reg .pred  first;

      ld.param.u64  %cd0, [pins];
      mov.u32       %tidx, %ctaid.z;
      mov.u32       %tidy, %ctaid.y;
      cvt.u64.u32   %tidz, %ctaid.x;

      // (%cd1) input.offset = input + (tid.x * sx + tid.y * sy * ix + tid.z * ix * iy) * float_size
      mul.wide.u32  %cd1, %tidx, <%= var(ctx, :sx) %>;
      mad.wide.u32  %cd1, %tidy, <%= var(ctx, :sy) * var(ctx, :x) %>, %cd1;
      mad.lo.u64    %cd1, %tidz, <%= var(ctx, :x) * var(ctx, :y) %>, %cd1;
      mad.lo.u64    %cd1, %cd1, <%= var(ctx, :float_size) %>, %cd0;
      <%= if offset(ctx, :input) > 0 do %>
        add.u64     %cd1, %cd1, <%= offset(ctx, :input) %>;
      <% end %>

      // (%cd2) output.offset = output + (tid.x + tid.y * ox + tid.z * ox * oy) * float_size
      cvt.u64.u32   %cd2, %tidx;
      mad.wide.u32  %cd2, %tidy, <%= var(ctx, :ox) %>, %cd2;
      mad.lo.u64    %cd2, %tidz, <%= var(ctx, :ox) * var(ctx, :oy) %>, %cd2;
      mad.lo.u64    %cd2, %cd2, <%= var(ctx, :float_size) %>, %cd0;
      <%= if offset(ctx, :output) > 0 do %>
        add.u64     %cd2, %cd2, <%= offset(ctx, :output) %>;
      <% end %>

      // %first - first item flag
      setp.eq.u32   first, 1, 1;
      // %tidy - py
      mov.u32       %tidy, <%= var(ctx, :py) %>;

    loop_y:
      mov.u32       %tidx, <%= var(ctx, :px) %>;
    loop_x:
      // acc = first ? [input] : max(acc, [input])
      ld.global.<%= var(ctx, :f) %> %f1, [%cd1];
      @!first max.<%= var(ctx, :f) %> %f0, %f0, %f1;
      @first  mov.<%= var(ctx, :f) %> %f0, %f1;
      @first  setp.eq.u32  first, 1, 0;
      // next point
      add.u64       %cd1, %cd1, <%= var(ctx, :float_size) %>;
      // count x
      sub.u32       %tidx, %tidx, 1;
      setp.ne.u32   p, %tidx, 0;
      @p bra        loop_x;
      // next line
      add.u64       %cd1, %cd1, <%= (var(ctx, :x) - var(ctx, :px)) * var(ctx, :float_size) %>;
      // count y
      sub.u32       %tidy, %tidy, 1;
      setp.ne.u32   p, %tidy, 0;
      @p bra        loop_y;

      st.global.<%= var(ctx, :f) %> [%cd2], %f0;
      ret;
    <% end %>
    """
  end

  defp back_ptx() do
    """
    .version 5.0
    .target sm_30
    .address_size 64

    <%= defkernel ctx, "back", shared: u64.ptr do %>
      ret;
    <% end %>
    """
  end

  def vars(opts, %{gpu_info: info}) do
    {x, y, z} =  opts |> Keyword.get(:size) |> Base.triple_size()
    {px, py} =   opts |> Keyword.get(:pooling) |> get_pooling_size()
    {sx, sy} =   opts |> Keyword.get(:stride) |> Base.stride()
    float_size = opts |> Keyword.get(:float_size) |> Base.float_size()
    f = "f#{float_size * 8}"

    ox = round((x - px + sx) / sx)
    oy = round((y - py + sy) / sy)
    oz = z

    {block, grid} = Convolution.cta(ox, oy, oz, info)

    %{x: x, y: y, z: z,
      ox: ox, oy: oy, oz: oz,
      px: px, py: py,
      sx: sx, sy: sy,
      grid: grid, block: block,
      f: f, float_size: float_size}
  end

  defp get_pooling_size({_, _} = tuple), do: tuple
  defp get_pooling_size(x), do: {x, x}
end
