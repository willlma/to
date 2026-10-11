defmodule ToWeb.CoreComponents do
  use Phoenix.Component

  attr :user, :any, default: nil

  def person_circle(assigns) do
    ~H"""
    <span class="person-circle" aria-hidden="true">{if @user, do: String.first(@user.name)}</span>
    """
  end
end
