# Cria ou altera um prestador e os exames que ele faz (contrato §5). A API
# nunca grava `simulated` (só a semente de dev). `items` presente = lista
# final (os ausentes saem).
module Exams
  module SaveProvider
    module_function

    def call(params, provider: nil)
      params = (params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h).deep_stringify_keys
      attrs = {}
      if params.key?("name") || provider.nil?
        name = params["name"].is_a?(String) ? params["name"].strip : ""
        return Result.fail(:invalid_name) unless name.length.between?(1, 120)

        attrs[:name] = name
      end
      if params.key?("kind") || provider.nil?
        return Result.fail(:invalid_kind) unless ExamProvider::KINDS.include?(params["kind"])

        attrs[:kind] = params["kind"]
      end
      if params.key?("cnes")
        cnes = params["cnes"]
        return Result.fail(:invalid_cnes) unless cnes.nil? || (cnes.is_a?(String) && cnes.match?(/\A\d{7}\z/))

        attrs[:cnes] = cnes
      end
      if params.key?("active")
        return Result.fail(:invalid_active) unless [ true, false ].include?(params["active"])

        attrs[:active] = params["active"]
      end
      # ADR 0037 (Desvio 13): laboratório municipal, endereço e telefone (art. 167, II).
      if params.key?("uses_municipal_lab")
        return Result.fail(:invalid_uses_municipal_lab) unless [ true, false ].include?(params["uses_municipal_lab"])
        # Dashboard D20: marcar só com municipal_lab utilizável (lido fora da transação).
        return Result.fail(:municipal_lab_disabled) if params["uses_municipal_lab"] && !Lab::Gate.usable?(Current.city)

        attrs[:uses_municipal_lab] = params["uses_municipal_lab"]
      end
      if params.key?("address")
        address = params["address"]
        return Result.fail(:invalid_address) unless address.nil? || (address.is_a?(String) && address.strip.length.between?(1, 200))

        attrs[:address] = address&.strip
      end
      if params.key?("phone")
        phone = params["phone"]
        return Result.fail(:invalid_phone) unless phone.nil? || (phone.is_a?(String) && phone.match?(/\A\d{10,11}\z/))

        attrs[:phone] = phone
      end
      items = params.key?("items") ? items(params["items"]) : nil
      return items if items.is_a?(Result)

      ApplicationRecord.transaction do
        provider ||= ExamProvider.new
        provider.update!(attrs)
        replace_items!(provider, items) if items
      end
      Result.ok(provider: provider)
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:duplicate_name)
    end

    def items(raw)
      return Result.fail(:invalid_items) unless raw.is_a?(Array) && raw.size <= 200

      list = raw.map do |entry|
        entry = entry.is_a?(Hash) ? entry.deep_stringify_keys : {}
        id = entry["catalog_item_id"]
        item = id.is_a?(String) && id.match?(Exams::BaseController::UUID) && ExamCatalogItem.find_by(id: id)
        return Result.fail(:invalid_items) unless item

        days = CatalogInput.send(:deadlines, entry["deadlines"] || {})
        return Result.fail(:invalid_deadline) unless days

        [ item, days ]
      end
      list.map { |i, _| i.id }.uniq.size == list.size ? list : Result.fail(:invalid_items)
    end

    def replace_items!(provider, items)
      provider.items.where.not(exam_catalog_item_id: items.map { |item, _| item.id }).delete_all
      items.each do |item, days|
        row = provider.items.find_or_initialize_by(exam_catalog_item_id: item.id)
        row.update!(Deadlines::STAGES.to_h { |stage| [ :"#{stage}_days", nil ] }.merge(days))
      end
    end
    private_class_method :items, :replace_items!
  end
end
