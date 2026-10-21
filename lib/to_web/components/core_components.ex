defmodule ToWeb.CoreComponents do
  use Phoenix.Component

  attr :user, :any, default: nil

  def person_circle(assigns) do
    ~H"""
    <style :type={ToWeb.ColocatedCSS}>
      .person-circle { display: flex; align-items: center; justify-content: center; box-sizing: border-box; width: 1.5rem; height: 1.5rem; border: 1px solid light-dark(#888, #aaa); border-radius: 50%; font-size: .75rem; }
    </style>
    <span class="person-circle" aria-hidden="true">{if @user, do: String.first(@user.name)}</span>
    """
  end

  def pen_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d="m16 4 4 4M4 20l4-1L20 7a2.1 2.1 0 0 0-3-3L5 16Z" />
    </svg>
    """
  end

  def trash_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7m4-7v7" />
    </svg>
    """
  end
end
