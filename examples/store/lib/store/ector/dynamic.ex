defmodule Store.Ector.Dynamic do
  @moduledoc """
  Executable dynamic-schema showcase for Ector.

  Relational systems need a migration before a new persisted type or ad hoc
  attribute can be stored safely. Ector only needs a schema module for hydration;
  the physical storage remains the same `nodes` table.
  """

  import Ector

  alias Store.Ector.Product

  defmodule Review do
    @moduledoc """
    Product review node added without a storage migration.

    The module compiles to a new logical label (`Review`) but still persists into
    Ector's existing `nodes` table.
    """

    use Ector.Node

    schema do
      field(:sku, :string)
      field(:rating, :integer)
      field(:body, :string)
    end

    @type t :: %__MODULE__{}
  end

  @doc """
  Runs the dynamic-schema demonstration against the given Ector repo.

  The result contains a hydrated unmigrated `Review` node and a projection of
  runtime-only `Product` attributes that were never declared in the product
  schema or any migration.
  """
  @spec run(module()) :: %{
          product: Product.t(),
          review: Review.t(),
          runtime_attributes: map()
        }
  def run(repo \\ Store.EctorRepo) do
    {:ok, %Product{} = product} =
      repo.insert(
        Product.changeset(%Product{}, %{
          id: "dyn-prod-1",
          sku: "SKU-DYN",
          name: "Field Repair Kit",
          category: "tools",
          price: 49.0,
          status: "active"
        })
      )

    {1, _} =
      Product
      |> from()
      |> where([product], product.sku == ^"SKU-DYN")
      |> repo.update_all(set: [warranty_months: 24, clearance: true])

    {:ok, %Review{} = review} =
      repo.insert(
        Review.changeset(%Review{}, %{
          id: "review-1",
          sku: "SKU-DYN",
          rating: 5,
          body: "Durable enough for the demo bench."
        })
      )

    runtime_attributes =
      Product
      |> from()
      |> where([product], product.warranty_months == ^24)
      |> select([product], %{
        sku: product.sku,
        warranty_months: product.warranty_months,
        clearance: product.clearance
      })
      |> repo.one()

    hydrated_review =
      Review
      |> from()
      |> where([review], review.sku == ^"SKU-DYN")
      |> repo.one()

    %{product: product, review: hydrated_review || review, runtime_attributes: runtime_attributes}
  end
end
