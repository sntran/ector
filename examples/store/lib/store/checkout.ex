defmodule Store.Checkout do
  @moduledoc """
  Checkout read workflows over the Ector graph.

  Cart summaries load the selected cart directly, then preload
  `Cart -> CartItem -> Offer -> Product` without duplicating image arrays onto
  offer nodes.
  """

  alias Store.Catalog.Offer
  alias Store.Checkout.{Cart, CartItem}
  alias Store.Repo

  alias Ecto.Multi

  require Ector

  @type cart_item_summary :: %{
          item_id: String.t(),
          quantity: integer(),
          price_at_addition: integer(),
          offer: %{
            id: String.t(),
            offered_by: String.t(),
            product_id: String.t(),
            product_name: String.t(),
            product_description: String.t()
          },
          product: %{
            id: String.t(),
            images: [String.t()]
          }
        }

  @type cart_summary :: %{
          id: String.t(),
          status: String.t(),
          item_count: non_neg_integer(),
          quantity_total: non_neg_integer(),
          subtotal: integer(),
          items: [cart_item_summary()]
        }

  @type checkout_result ::
          {:ok, cart_summary()} | {:error, :empty_cart | :not_active | :out_of_stock}

  @doc "Default cart id used by the LiveView storefront."
  @spec default_cart_id() :: String.t()
  def default_cart_id do
    System.get_env("STORE_CART_ID") || "demo-cart"
  end

  @doc """
  Loads a cart summary by traversing Cart -> CartItem -> Offer -> Product.
  """
  @spec get_cart_summary(String.t()) :: cart_summary() | nil
  def get_cart_summary(cart_id) when is_binary(cart_id) do
    case get_cart(cart_id) do
      nil -> nil
      cart -> get_cart_summary_for_cart(cart)
    end
  end

  defp get_cart_summary_for_cart(%Cart{} = selected_cart) do
    selected_cart
    |> Repo.preload(items: [offer: :product])
    |> build_summary()
  end

  @doc "Returns one cart projection by its business id."
  @spec get_cart(String.t()) :: Cart.t() | nil
  def get_cart(cart_id) when is_binary(cart_id) do
    Cart
    |> Ector.from()
    |> Ector.where([cart], cart.id == ^cart_id)
    |> Repo.all()
    |> current_cart()
  end

  @doc "Ensures the LiveView storefront has an active cart to mutate."
  @spec ensure_active_cart!(String.t()) :: Cart.t()
  def ensure_active_cart!(cart_id \\ default_cart_id()) when is_binary(cart_id) do
    case get_cart(cart_id) do
      %{status: "active"} = cart -> cart
      nil -> insert_cart!(cart_id)
      _converted_or_abandoned -> create_active_cart!(cart_id)
    end
  end

  @doc "Creates a new empty active cart for continued shopping after checkout."
  @spec create_active_cart!(String.t()) :: Cart.t()
  def create_active_cart!(cart_id \\ default_cart_id()) when is_binary(cart_id) do
    insert_cart!(cart_id)
  end

  @doc "Adds one offer to the cart and snapshots its current price."
  @spec add_offer_to_cart(String.t(), String.t(), pos_integer()) :: cart_summary()
  def add_offer_to_cart(cart_id, offer_id, quantity \\ 1)
      when is_binary(cart_id) and is_binary(offer_id) and is_integer(quantity) and quantity > 0 do
    cart = ensure_active_cart!(cart_id)
    offer = get_offer_node!(offer_id)

    case get_cart_items_for_offer(cart.__id__, offer.__id__) do
      [] ->
        insert_cart_item!(cart, offer, quantity)

      items ->
        merge_cart_items!(items, quantity)
    end

    get_cart_summary(cart.id)
  end

  defp insert_cart_item!(cart, offer, quantity) do
    attrs = %{
      id: business_id(),
      cart_id: cart.__id__,
      offer_id: offer.__id__,
      quantity: quantity,
      price_at_addition: offer.price
    }

    %CartItem{}
    |> CartItem.changeset(attrs)
    |> insert!("cart item")
  end

  defp merge_cart_items!([primary | duplicates], added_quantity) do
    total_quantity =
      primary.quantity + added_quantity + Enum.reduce(duplicates, 0, &(&1.quantity + &2))

    primary
    |> CartItem.changeset(%{quantity: total_quantity})
    |> update!("cart item")

    Enum.each(duplicates, fn item ->
      Repo.delete(item)
    end)
  end

  @doc "Updates a cart item's quantity when the item belongs to the cart."
  @spec update_cart_item_quantity(String.t(), String.t(), pos_integer()) :: cart_summary() | nil
  def update_cart_item_quantity(cart_id, item_id, quantity)
      when is_binary(cart_id) and is_binary(item_id) and is_integer(quantity) and quantity > 0 do
    with %CartItem{} = item <- get_cart_item_for_cart(cart_id, item_id) do
      item
      |> CartItem.changeset(%{quantity: quantity})
      |> Repo.update()
    end

    get_cart_summary(cart_id)
  end

  @doc "Removes a cart item when the item belongs to the cart."
  @spec remove_cart_item(String.t(), String.t()) :: cart_summary() | nil
  def remove_cart_item(cart_id, item_id) when is_binary(cart_id) and is_binary(item_id) do
    with %CartItem{} = item <- get_cart_item_for_cart(cart_id, item_id) do
      Repo.delete(item)
    end

    get_cart_summary(cart_id)
  end

  @doc """
  Processes the active cart with guarded, database-level offer stock decrements.

  Offer stock is decremented directly inside the shared `nodes.properties`
  payload. Each update is guarded by the current JSON quantity so concurrent
  checkout attempts cannot over-allocate inventory.
  """
  @spec process_checkout(String.t()) :: checkout_result()
  def process_checkout(cart_id) when is_binary(cart_id) do
    case get_cart(cart_id) do
      nil ->
        {:error, :empty_cart}

      %{status: status} when status != "active" ->
        {:error, :not_active}

      _cart ->
        process_active_checkout(cart_id)
    end
  end

  @doc "Marks the active cart converted."
  @spec complete_checkout(String.t()) :: cart_summary() | nil
  def complete_checkout(cart_id) when is_binary(cart_id) do
    case process_checkout(cart_id) do
      {:ok, summary} -> summary
      {:error, _reason} -> get_cart_summary(cart_id)
    end
  end

  defp build_summary(%Cart{} = cart) do
    items =
      cart
      |> loaded_association(:items, [])
      |> Enum.map(&item_summary/1)
      |> Enum.sort_by(& &1.item_id)

    %{
      id: cart.id,
      status: cart.status,
      item_count: length(items),
      quantity_total: Enum.reduce(items, 0, &(&1.quantity + &2)),
      subtotal: Enum.reduce(items, 0, &(&1.quantity * &1.price_at_addition + &2)),
      items: items
    }
  end

  defp current_cart([]), do: nil

  defp current_cart(carts) do
    carts
    |> Enum.sort_by(
      fn cart -> {if(cart.status == "active", do: 1, else: 0), cart.__id__} end,
      :desc
    )
    |> List.first()
  end

  defp item_summary(%CartItem{} = item) do
    offer = loaded_association!(item, :offer)
    product = loaded_association!(offer, :product)

    %{
      item_id: item.id,
      quantity: item.quantity,
      price_at_addition: item.price_at_addition,
      offer: %{
        id: offer.id,
        offered_by: offer.offered_by,
        product_id: offer.product_id,
        product_name: offer.product_name,
        product_description: offer.product_description
      },
      product: %{
        id: product.id,
        images: normalize_images(product.images)
      }
    }
  end

  defp loaded_association(struct, key, default) when is_map(struct) and is_atom(key) do
    Map.get(struct, key, default)
  end

  defp loaded_association!(struct, key) when is_map(struct) and is_atom(key) do
    case Map.fetch(struct, key) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: struct
    end
  end

  defp normalize_images(images) when is_list(images), do: images

  defp normalize_images(images) when is_binary(images) do
    case JSON.decode(images) do
      {:ok, decoded} when is_list(decoded) -> decoded
      _other -> [images]
    end
  end

  defp normalize_images(_images), do: []

  defp process_active_checkout(cart_id) do
    case checkout_stock_lines(cart_id) do
      [] ->
        {:error, :empty_cart}

      lines ->
        cart_id
        |> checkout_multi(lines)
        |> Repo.transact()
        |> case do
          {:ok, %{summary: summary}} ->
            {:ok, summary}

          {:error, _step, reason, _changes} when reason in [:not_active, :out_of_stock] ->
            {:error, reason}
        end
    end
  end

  defp checkout_multi(cart_id, lines) do
    Multi.new()
    |> Multi.run(:decrement_stock, fn repo, _changes ->
      decrement_stock_lines(repo, aggregate_stock_lines(lines))
    end)
    |> Multi.run(:convert_cart, fn repo, _changes ->
      convert_active_cart(repo, cart_id)
    end)
    |> Multi.run(:summary, fn _repo, _changes ->
      {:ok, get_cart_summary(cart_id)}
    end)
  end

  defp decrement_stock_lines(repo, lines) do
    Enum.reduce_while(lines, {:ok, []}, fn %{offer_id: offer_id, quantity: quantity},
                                           {:ok, acc} ->
      case decrement_offer_stock(repo, offer_id, quantity) do
        :ok -> {:cont, {:ok, [offer_id | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp checkout_stock_lines(cart_id) do
    case get_cart(cart_id) do
      %{status: "active"} = cart ->
        cart
        |> cart_items_for_cart()
        |> Repo.preload(:offer)
        |> Enum.map(fn item ->
          offer = loaded_association!(item, :offer)
          %{offer_id: offer.id, quantity: item.quantity}
        end)

      _missing_or_inactive ->
        []
    end
  end

  defp aggregate_stock_lines(lines) do
    lines
    |> Enum.group_by(& &1.offer_id, & &1.quantity)
    |> Enum.map(fn {offer_id, quantities} ->
      %{offer_id: offer_id, quantity: Enum.sum(quantities)}
    end)
  end

  defp convert_active_cart(repo, cart_id) do
    {updated, _result} =
      Cart
      |> Ector.from()
      |> Ector.where([cart], cart.id == ^cart_id and cart.status == ^"active")
      |> Ector.Repo.update_all(repo, set: [status: "converted"])

    case updated do
      1 -> {:ok, :converted}
      0 -> {:error, :not_active}
    end
  end

  defp decrement_offer_stock(repo, offer_id, quantity) do
    query =
      Offer
      |> Ector.from()
      |> Ector.where([offer], offer.id == ^offer_id and offer.quantity > 0)
      |> Ector.where([offer], offer.quantity >= ^quantity)

    case query |> Ector.Repo.update_all(repo, inc: [quantity: -quantity]) do
      {1, _result} -> :ok
      {0, _result} -> {:error, :out_of_stock}
    end
  end

  defp get_cart_items_for_offer(cart_storage_id, offer_storage_id) do
    CartItem
    |> Ector.from()
    |> Ector.where(
      [item],
      item.cart_id == ^cart_storage_id and item.offer_id == ^offer_storage_id
    )
    |> Repo.all()
    |> Enum.sort_by(& &1.__id__)
  end

  defp get_cart_item_for_cart(cart_id, item_id) do
    with %Cart{} = cart <- get_cart(cart_id) do
      cart
      |> cart_items_for_cart()
      |> Enum.find(&(&1.id == item_id))
    end
  end

  defp insert_cart!(cart_id) do
    %Cart{}
    |> Cart.changeset(%{id: cart_id, status: "active"})
    |> insert!("cart")
  end

  defp get_offer_node!(offer_id) do
    Offer
    |> Ector.from()
    |> Ector.where([offer], offer.id == ^offer_id)
    |> Ector.select([offer], %{id: offer.id, __id__: offer.__id__, price: offer.price})
    |> Repo.all()
    |> List.first()
    |> case do
      nil -> raise ArgumentError, "unknown offer #{inspect(offer_id)}"
      offer -> offer
    end
  end

  defp cart_items_for_cart(%Cart{__id__: cart_storage_id}) when is_binary(cart_storage_id) do
    CartItem
    |> Ector.from()
    |> Ector.where([item], item.cart_id == ^cart_storage_id)
    |> Repo.all()
    |> Enum.sort_by(& &1.id)
  end

  defp cart_items_for_cart(_cart), do: []

  defp business_id do
    Ecto.UUID.generate(version: 7, precision: :monotonic)
  end

  defp insert!(changeset, label) do
    case Repo.insert(changeset) do
      {:ok, struct} -> struct
      {:error, changeset} -> raise_invalid_changeset!(label, changeset)
    end
  end

  defp update!(changeset, label) do
    case Repo.update(changeset) do
      {:ok, struct} -> struct
      {:error, changeset} -> raise_invalid_changeset!(label, changeset)
    end
  end

  defp raise_invalid_changeset!(label, changeset) do
    raise ArgumentError,
          "invalid #{label}: #{inspect(changeset.errors)}"
  end
end
