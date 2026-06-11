defmodule Store.Catalog do
  @moduledoc """
  Catalog read workflows for the zero-migration storefront.

  Listing queries stay on `Store.Catalog.Offer` properties. Product images are
  fetched only by checkout graph reads that need the final product hop.
  """

  import Ecto.Query, only: [limit: 2]

  alias Store.Catalog.Offer
  alias Store.Repo

  require Ector

  @default_limit 25
  @max_limit 100

  @type offer_entry :: %{
          id: String.t(),
          cursor: Ecto.UUID.t(),
          product_id: String.t(),
          offered_by: String.t(),
          price: integer(),
          quantity: integer(),
          product_name: String.t(),
          product_description: String.t()
        }

  @type offer_page :: %{
          entries: [offer_entry()],
          next_cursor: String.t() | nil,
          previous_cursor: String.t() | nil
        }

  @doc """
  Lists offers with cursor pagination over descending Ector storage identity.

  Supported filters are `:product_id`, `:offered_by`, `:min_price`,
  `:max_price`, and `:search`. Search checks only the denormalized text already
  present on each offer node.
  """
  @spec list_offers(keyword() | map()) :: offer_page()
  def list_offers(opts \\ [])

  def list_offers(opts) when is_list(opts) or is_map(opts) do
    limit = page_limit(opt(opts, :limit, @default_limit))
    sort = normalize_sort(opt(opts, :sort, :newest))
    direction = page_direction(opts)
    page_size = limit + 1
    search = opt(opts, :q) || opt(opts, :search)

    query =
      Offer
      |> Ector.from()
      |> apply_page_cursor(direction)
      |> apply_exact_filter(:product_id, opt(opts, :product_id))
      |> apply_exact_filter(:offered_by, opt(opts, :offered_by))
      |> apply_price_filter(:min_price, opt(opts, :min_price))
      |> apply_price_filter(:max_price, opt(opts, :max_price))
      |> apply_search(search)
      |> apply_sort(sort, direction)
      |> limit(^page_size)
      |> Ector.select([offer], %{
        id: offer.id,
        cursor: offer.__id__,
        product_id: offer.product_id,
        offered_by: offer.offered_by,
        price: offer.price,
        quantity: offer.quantity,
        product_name: offer.product_name,
        product_description: offer.product_description
      })

    rows = Repo.all(query)
    build_page(sort, direction, rows, limit)
  end

  @doc "Returns the vendor names currently present on offers."
  @spec list_vendors() :: [String.t()]
  def list_vendors do
    Offer
    |> Ector.from()
    |> Ector.select([offer], offer.offered_by)
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Lists offer cards for the LiveView catalog.

  Filtering and sorting still target `Offer` properties. The product join is
  added only to display images for the visible page.
  """
  @spec list_offer_cards(keyword() | map()) :: [map()]
  def list_offer_cards(opts \\ []) when is_list(opts) or is_map(opts) do
    opts
    |> list_offer_cards_page()
    |> Map.fetch!(:entries)
  end

  @doc """
  Lists one cursor page of offer cards for the LiveView catalog.
  """
  @spec list_offer_cards_page(keyword() | map()) :: %{
          entries: [map()],
          next_cursor: String.t() | nil,
          previous_cursor: String.t() | nil
        }
  def list_offer_cards_page(opts \\ []) when is_list(opts) or is_map(opts) do
    limit = page_limit(opt(opts, :limit, @default_limit))
    sort = normalize_sort(opt(opts, :sort, :newest))
    direction = page_direction(opts)
    page_size = limit + 1
    search = opt(opts, :q) || opt(opts, :search)

    rows =
      Offer
      |> Ector.from()
      |> apply_page_cursor(direction)
      |> apply_exact_filter(:product_id, opt(opts, :product_id))
      |> apply_exact_filter(:offered_by, opt(opts, :offered_by))
      |> apply_price_filter(:min_price, opt(opts, :min_price))
      |> apply_price_filter(:max_price, opt(opts, :max_price))
      |> apply_search(search)
      |> Ector.join(:product, as: :product)
      |> apply_sort(sort, direction)
      |> limit(^page_size)
      |> Ector.select([offer, product: product], %{
        id: offer.id,
        cursor: offer.__id__,
        product_id: offer.product_id,
        offered_by: offer.offered_by,
        price: offer.price,
        quantity: offer.quantity,
        product_name: offer.product_name,
        product_description: offer.product_description,
        images: product.images
      })
      |> Repo.all()
      |> Enum.map(&Map.update!(&1, :images, fn images -> normalize_images(images) end))

    build_page(sort, direction, rows, limit)
  end

  @doc "Returns compact offer matches for the global header search."
  @spec search_suggestions(String.t(), keyword()) :: [offer_entry()]
  def search_suggestions(query, opts \\ []) when is_binary(query) do
    if String.trim(query) == "" do
      []
    else
      opts
      |> Keyword.put(:q, query)
      |> Keyword.put_new(:limit, 6)
      |> list_offers()
      |> Map.fetch!(:entries)
    end
  end

  @doc "Encodes a catalog cursor token for the supplied storage anchor and direction."
  @spec cursor_token(Ecto.UUID.t(), :next | :prev | String.t()) :: String.t()
  def cursor_token(anchor_id, dir) when dir in [:next, :prev] do
    cursor_token(anchor_id, Atom.to_string(dir))
  end

  def cursor_token(anchor_id, dir) when is_binary(anchor_id) and dir in ["next", "prev"] do
    case Ecto.UUID.cast(anchor_id) do
      {:ok, anchor_id} ->
        %{value: anchor_id, dir: dir}
        |> JSON.encode_to_iodata!()
        |> IO.iodata_to_binary()
        |> Base.url_encode64(padding: false)

      :error ->
        raise ArgumentError, "expected a valid Ector storage cursor, got: #{inspect(anchor_id)}"
    end
  end

  @doc "Loads one offer plus its product image payload."
  @spec get_offer_details(String.t()) :: map() | nil
  def get_offer_details(offer_id) when is_binary(offer_id) do
    Offer
    |> Ector.from()
    |> Ector.join(:product, as: :product)
    |> Ector.where([offer], offer.id == ^offer_id)
    |> Ector.select([offer, product: product], %{
      id: offer.id,
      cursor: offer.__id__,
      product_id: offer.product_id,
      offered_by: offer.offered_by,
      price: offer.price,
      quantity: offer.quantity,
      product_name: offer.product_name,
      product_description: offer.product_description,
      product_images: product.images
    })
    |> Repo.one()
    |> normalize_offer_detail()
  end

  @doc "Returns the current quantity for one offer."
  @spec get_offer_stock(String.t()) :: integer() | nil
  def get_offer_stock(offer_id) when is_binary(offer_id) do
    Offer
    |> Ector.from()
    |> Ector.where([offer], offer.id == ^offer_id)
    |> Ector.select([offer], offer.quantity)
    |> Repo.one()
  end

  defp apply_page_cursor(query, :initial), do: query

  defp apply_page_cursor(query, {:next, cursor}) when is_binary(cursor) do
    Ector.where(query, [offer], offer.__id__ < ^cursor)
  end

  defp apply_page_cursor(query, {:prev, cursor}) when is_binary(cursor) do
    Ector.where(query, [offer], offer.__id__ > ^cursor)
  end

  defp apply_exact_filter(query, _field, nil), do: query
  defp apply_exact_filter(query, _field, ""), do: query

  defp apply_exact_filter(query, :product_id, product_id) do
    Ector.where(query, [offer], offer.product_id == ^product_id)
  end

  defp apply_exact_filter(query, :offered_by, offered_by) do
    Ector.where(query, [offer], offer.offered_by == ^offered_by)
  end

  defp apply_price_filter(query, _field, nil), do: query

  defp apply_price_filter(query, :min_price, price) when is_integer(price) do
    Ector.where(query, [offer], offer.price >= ^price)
  end

  defp apply_price_filter(query, :max_price, price) when is_integer(price) do
    Ector.where(query, [offer], offer.price <= ^price)
  end

  defp apply_search(query, nil), do: query
  defp apply_search(query, ""), do: query

  defp apply_search(query, search) when is_binary(search) do
    pattern = "%#{String.downcase(search)}%"

    Ector.where(
      query,
      [offer],
      fragment("lower(?) LIKE ?", offer.product_name, ^pattern) or
        fragment("lower(?) LIKE ?", offer.product_description, ^pattern) or
        fragment("lower(?) LIKE ?", offer.offered_by, ^pattern)
    )
  end

  defp apply_sort(query, _sort, {:prev, _cursor}),
    do: Ector.order_by(query, [offer], asc: offer.__id__)

  defp apply_sort(query, _sort, {:next, _cursor}),
    do: Ector.order_by(query, [offer], desc: offer.__id__)

  defp apply_sort(query, :price_asc, _direction),
    do: Ector.order_by(query, [offer], asc: offer.price, asc: offer.__id__)

  defp apply_sort(query, :price_desc, _direction),
    do: Ector.order_by(query, [offer], desc: offer.price, desc: offer.__id__)

  defp apply_sort(query, :newest, _direction),
    do: Ector.order_by(query, [offer], desc: offer.__id__)

  defp normalize_sort(sort) when sort in [:newest, :price_asc, :price_desc], do: sort
  defp normalize_sort("price_asc"), do: :price_asc
  defp normalize_sort("price_desc"), do: :price_desc
  defp normalize_sort("newest"), do: :newest
  defp normalize_sort(_sort), do: :newest

  defp page_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)

  defp page_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} -> page_limit(parsed)
      _other -> @default_limit
    end
  end

  defp page_limit(_limit), do: @default_limit

  defp page_direction(opts) do
    case decode_cursor_token(opt(opts, :cursor)) do
      {:ok, direction} -> direction
      :error -> :initial
    end
  end

  defp build_page(sort, direction, rows, limit) do
    {entries, overflow} = Enum.split(rows, limit)
    entries = maybe_restore_page_order(entries, direction)

    %{
      entries: entries,
      next_cursor: next_cursor(sort, direction, entries, overflow),
      previous_cursor: previous_cursor(sort, direction, entries, overflow)
    }
  end

  defp maybe_restore_page_order(entries, {:prev, _cursor}), do: Enum.reverse(entries)
  defp maybe_restore_page_order(entries, _direction), do: entries

  defp next_cursor(_sort, _direction, [], _overflow), do: nil

  defp next_cursor(_sort, {:prev, _cursor}, entries, _overflow),
    do: cursor_for(List.last(entries), :next)

  defp next_cursor(_sort, _direction, _entries, []), do: nil

  defp next_cursor(_sort, _direction, entries, _overflow),
    do: cursor_for(List.last(entries), :next)

  defp previous_cursor(_sort, _direction, [], _overflow), do: nil
  defp previous_cursor(_sort, :initial, _entries, _overflow), do: nil

  defp previous_cursor(_sort, {:next, _cursor}, entries, _overflow),
    do: cursor_for(List.first(entries), :prev)

  defp previous_cursor(_sort, {:prev, _cursor}, _entries, []), do: nil

  defp previous_cursor(_sort, {:prev, _cursor}, entries, _overflow),
    do: cursor_for(List.first(entries), :prev)

  defp cursor_for(entry, dir) do
    entry
    |> Map.fetch!(:cursor)
    |> cursor_token(dir)
  end

  defp decode_cursor_token(nil), do: :error
  defp decode_cursor_token(""), do: :error

  defp decode_cursor_token(cursor) when is_binary(cursor) do
    with {:ok, json} <- url_decode64(cursor),
         {:ok, %{"value" => value, "dir" => dir}} <- JSON.decode(json),
         {:ok, value} <- Ecto.UUID.cast(value),
         true <- dir in ["next", "prev"] do
      {:ok, {String.to_existing_atom(dir), value}}
    else
      _other -> :error
    end
  end

  defp decode_cursor_token(_cursor), do: :error

  defp url_decode64(cursor) do
    case Base.url_decode64(cursor, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.url_decode64(cursor)
    end
  end

  defp normalize_offer_detail(nil), do: nil

  defp normalize_offer_detail(offer) do
    offer
    |> Map.put(:product_images, normalize_images(offer.product_images))
    |> Map.put(:images, normalize_images(offer.product_images))
    |> Map.delete(:product_images)
  end

  defp normalize_images(images) when is_list(images), do: images

  defp normalize_images(images) when is_binary(images) do
    case JSON.decode(images) do
      {:ok, decoded} when is_list(decoded) -> decoded
      _other -> [images]
    end
  end

  defp normalize_images(_images), do: []

  defp opt(opts, key, default \\ nil)
  defp opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)

  defp opt(opts, key, default) when is_map(opts) do
    Map.get(opts, key, Map.get(opts, Atom.to_string(key), default))
  end
end
