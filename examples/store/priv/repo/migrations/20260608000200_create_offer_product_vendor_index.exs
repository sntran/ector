defmodule Store.Repo.Migrations.CreateOfferProductVendorIndex do
  use Ector.Migration

  def change do
    create(
      index(Store.Catalog.Offer, [:product_id, :offered_by],
        unique: true,
        name: :store_offers_product_id_offered_by_uidx
      )
    )
  end
end
