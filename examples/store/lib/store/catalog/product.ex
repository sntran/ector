defmodule Store.Catalog.Product do
  @moduledoc """
  Catalog product stored as an Ector node.

  Product images remain on the product node. Offers cache only text fields that
  are needed by listing queries.
  """

  use Ector.Node

  import Ecto.Changeset

  alias Store.Catalog.Offer

  @required_fields [:id, :name, :description, :images]

  schema do
    field(:name, :string)
    field(:description, :string)
    field(:images, {:array, :string}, default: [])

    has_many(:offers, Offer)
  end

  @type t :: %__MODULE__{
          id: String.t() | nil,
          __id__: Ecto.UUID.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          images: [String.t()]
        }

  @spec changeset(t(), map() | keyword()) :: Ecto.Changeset.t()
  def changeset(product \\ %__MODULE__{}, attrs) do
    product
    |> cast(attrs, [:id, :name, :description, :images])
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 2, max: 160)
    |> validate_length(:description, min: 2, max: 2_000)
    |> validate_images()
  end

  defp validate_images(changeset) do
    images = get_field(changeset, :images) || []

    cond do
      images == [] ->
        add_error(changeset, :images, "must contain at least one image")

      Enum.all?(images, &valid_image?/1) ->
        changeset

      true ->
        add_error(changeset, :images, "must contain only absolute image URLs")
    end
  end

  defp valid_image?(image) when is_binary(image) do
    String.starts_with?(image, ["http://", "https://"])
  end

  defp valid_image?(_image), do: false
end
