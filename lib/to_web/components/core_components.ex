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
end
