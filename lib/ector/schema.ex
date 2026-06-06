defmodule Ector.Schema do
	@moduledoc false

	@type association_direction :: :incoming | :outgoing
	@type association_cardinality :: :one | :many
	@type association_kind :: :node | :edge

	@spec label_for(module(), association_kind()) :: String.t()
	def label_for(module, :node) when is_atom(module) do
		module
		|> Module.split()
		|> List.last()
	end

	def label_for(module, :edge) when is_atom(module) do
		module
		|> Module.split()
		|> List.last()
		|> Macro.underscore()
		|> String.upcase()
	end

	@spec association_metadata(module(), atom(), atom(), module(), keyword()) :: map()
	def association_metadata(owner, association_type, name, target, opts)
			when is_atom(owner) and is_atom(association_type) and is_atom(name) and is_atom(target) and
						 is_list(opts) do
		{cardinality, direction} = association_shape(association_type)

		%{
			cardinality: cardinality,
			direction: direction,
			name: name,
			opts: Enum.into(opts, %{}),
			owner: owner,
			target: target
		}
	end

	defmacro __using__(opts) do
		kind = Keyword.fetch!(opts, :kind)

		quote bind_quoted: [kind: kind] do
			use Ecto.Schema
			require Ector.Schema

			import Ector.Schema,
				only: [
					schema: 1,
					has_many: 2,
					has_many: 3,
					has_one: 2,
					has_one: 3,
					belongs_to: 2,
					belongs_to: 3
				]

			@before_compile Ector.Schema
			@ector_kind kind
			# Ector keeps storage identity separate from the caller's domain identity,
			# so we disable Ecto's implicit primary key before the schema body runs.
			@primary_key false

			Module.register_attribute(__MODULE__, :ector_associations, accumulate: true)
		end
	end

	defmacro __before_compile__(env) do
		kind = Module.get_attribute(env.module, :ector_kind)
		associations = env.module |> Module.get_attribute(:ector_associations) |> Enum.reverse()
		label = label_for(env.module, kind)
		table = storage_table_for(kind)

		quote do
			def __ector_kind__, do: @ector_kind
			def __ector_label__, do: unquote(label)
			def __ector_table__, do: unquote(table)
			def __ector_associations__, do: unquote(Macro.escape(associations))

			def changeset(struct \\ %__MODULE__{}, attrs)

			def changeset(struct, attrs) when is_list(attrs) do
				changeset(struct, Map.new(attrs))
			end

			def changeset(struct, attrs) when is_map(attrs) do
				struct
				|> Ecto.Changeset.cast(attrs, __schema__(:fields) -- [:__id__])
			end

			def changeset(struct, _attrs) do
				changeset(struct, %{})
			end
		end
	end

	defmacro schema(do: block) do
		# Association declarations need to resolve to Ector.Schema even while the
		# quoted body temporarily imports Ecto.Schema for its field macros.
		rewritten_block = rewrite_association_calls(block)

		prelude =
			quote do
				meta? = false
				source = nil
				prefix = Ecto.Schema.__schema__(__MODULE__, __ENV__.line, source, meta?, :binary_id)

				try do
					import Ecto.Schema

					# If the caller did not declare a primary key, provide a business-facing
					# identifier without tying it to the backend UUID that tracks topology.
					if Module.get_attribute(__MODULE__, :ecto_primary_keys) == [] do
						field :id, :string
					end

					# __id__ is Ector's hidden routing key. Repo hydration maps database UUIDs
					# back here explicitly so user-owned IDs never get overwritten.
					field :__id__, Ecto.UUID, autogenerate: [version: 7, precision: :monotonic]
					unquote(rewritten_block)
				after
					:ok
				end
			end

		postlude =
			quote unquote: false do
				{struct_fields, bags_of_clauses} = Ecto.Schema.__schema__(__MODULE__)
				defstruct struct_fields

				def __changeset__ do
					%{unquote_splicing(Macro.escape(@ecto_changeset_fields))}
				end

				def __schema__(:source), do: nil
				def __schema__(:prefix), do: unquote(Macro.escape(prefix))

				for clauses <- bags_of_clauses, {args, body} <- clauses do
					def __schema__(unquote_splicing(args)), do: unquote(body)
				end

				:ok
			end

		quote do
			unquote(prelude)
			unquote(postlude)
		end
	end

	defmacro has_many(name, target, opts \\ []) do
		target = Macro.expand(target, __CALLER__)
		association = association_metadata(__CALLER__.module, :has_many, name, target, opts)

		quote bind_quoted: [association: Macro.escape(association)] do
			@ector_associations association
		end
	end

	defmacro has_one(name, target, opts \\ []) do
		target = Macro.expand(target, __CALLER__)
		association = association_metadata(__CALLER__.module, :has_one, name, target, opts)

		quote bind_quoted: [association: Macro.escape(association)] do
			@ector_associations association
		end
	end

	defmacro belongs_to(name, target, opts \\ []) do
		target = Macro.expand(target, __CALLER__)
		association = association_metadata(__CALLER__.module, :belongs_to, name, target, opts)

		quote bind_quoted: [association: Macro.escape(association)] do
			@ector_associations association
		end
	end

	defp association_shape(:has_many), do: {:many, :outgoing}
	defp association_shape(:has_one), do: {:one, :outgoing}
	defp association_shape(:belongs_to), do: {:one, :incoming}

	defp storage_table_for(:node), do: :nodes
	defp storage_table_for(:edge), do: :edges

	defp rewrite_association_calls(block) do
		# Associations can appear anywhere inside the schema AST, so a prewalk lets
		# us redirect every call to Ector's metadata-recording macros in one pass.
		Macro.prewalk(block, fn
			{association, meta, args} when association in [:has_many, :has_one, :belongs_to] ->
				{{:., meta, [Ector.Schema, association]}, meta, args}

			node ->
				node
		end)
	end
end
