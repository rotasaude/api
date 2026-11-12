# POST/PATCH /ombudsman/subjects (ADR 0051; contrato §7): assunto ou subassunto
# (só dois níveis: neto → 422 too_deep, path parent_id). Nome 2..80 sem as
# bordas (Q8), único por pai sem distinguir caixa (409 name_taken). O pai não
# muda depois de criado. `subject: nil` cria.
module Ombudsman
  module SaveSubject
    module_function

    # -> Result.ok(subject:) | fail(:invalid_request | :too_deep, details: { path:, problems: }) | fail(:name_taken)
    def call(subject:, attrs:)
      attrs = attrs.to_h.stringify_keys
      name = Input.text(attrs["name"], Catalog::NAME) if attrs.key?("name") || subject.nil?
      return failure("name") if (attrs.key?("name") || subject.nil?) && name.nil?
      return failure("active") if attrs.key?("active") && ![ true, false ].include?(attrs["active"])

      OmbudsmanSubject.transaction(requires_new: true) do
        if subject
          changes = {}
          changes[:name] = name if name
          changes[:active] = attrs["active"] if attrs.key?("active")
          subject.update!(changes)
          next Result.ok(subject: subject)
        end

        parent = nil
        if attrs["parent_id"].present?
          parent = Input.uuid?(attrs["parent_id"]) ? OmbudsmanSubject.find_by(id: attrs["parent_id"]) : nil
          next failure("parent_id") unless parent
          next failure("parent_id", :too_deep) if parent.parent_id
        end
        position = OmbudsmanSubject.where(parent_id: parent&.id).maximum(:position).to_i + 1
        Result.ok(subject: OmbudsmanSubject.create!(name: name, parent: parent, position: position))
      end
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:name_taken)
    end

    def failure(path, error = :invalid_request)
      Result.fail(error, details: { path: path, problems: [ { error: error.to_s, path: path } ] })
    end

    private_class_method :failure
  end
end
