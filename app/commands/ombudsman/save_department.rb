# POST/PATCH /departments (ADR 0051; contrato §7): setor da secretaria. Nome
# 2..80 sem as bordas (Q8); repetido sem distinguir caixa → 409 name_taken
# (índice). Desativar um setor com encaminhamento pendente é permitido. Chave
# fora de name/active é ignorada. `department: nil` cria (nome obrigatório).
module Ombudsman
  module SaveDepartment
    module_function

    # -> Result.ok(department:) | fail(:invalid_request, details: { path:, problems: }) | fail(:name_taken)
    def call(department:, attrs:, by:)
      attrs = attrs.to_h.stringify_keys
      name = Input.text(attrs["name"], Catalog::NAME) if attrs.key?("name") || department.nil?
      problems = []
      problems << "name" if (attrs.key?("name") || department.nil?) && name.nil?
      problems << "active" if attrs.key?("active") && ![ true, false ].include?(attrs["active"])
      return failure(problems) if problems.any?

      Department.transaction(requires_new: true) do
        department ||= Department.new
        department.name = name if name
        department.active = attrs["active"] if attrs.key?("active")
        department.updated_by_user = by
        department.save!
        Result.ok(department: department)
      end
    rescue ActiveRecord::RecordNotUnique
      Result.fail(:name_taken)
    end

    def failure(paths)
      problems = paths.map { |path| { error: "invalid_request", path: path } }
      Result.fail(:invalid_request, details: { path: paths.first, problems: problems })
    end

    private_class_method :failure
  end
end
