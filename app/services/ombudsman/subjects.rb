# Assuntos reservados do centro de zoonoses na ouvidoria (módulo 35b, ADR
# 0054; contrato §4; Q14). Ligar o `zoonoses` não tem gancho na cidade, então
# os assuntos são garantidos sob demanda: no primeiro registro com
# `zoonoses_subtype` (Zoonoses::OpenDemand) e na listagem de assuntos com o
# gate ligado.
#
# `ensure_zoonoses!` garante o pai "Zoonoses" (code `zoonoses`) e os oito
# filhos (code `zoonoses.<subtipo>`, rótulos de config/zoonoses/domains.yml,
# os do §4 — a mesma fonte dos domínios do 35b):
# - idempotente: com os nove códigos já gravados e ativos, só lê;
# - senão, sob pg_advisory_xact_lock (a trava fica até o fim da transação de
#   fora, como as demais do repositório), relê e cria o que falta;
# - adota o pai sem code com o nome "Zoonoses" (sem distinguir caixa) e,
#   debaixo dele, o filho sem code com o nome do rótulo; o nome que a cidade
#   deu fica;
# - o assunto reservado desativado (com o gate desligado, SaveSubject deixa)
#   volta ativo: com o gate ligado ele não pode ficar inativo, e a
#   classificação automática precisa dele.
# A semente do 33 entra antes (OmbudsmanSubject.ensure_defaults! só semeia a
# tabela vazia: o reservado não pode ser o primeiro assunto da cidade).
module Ombudsman
  module Subjects
    PARENT_NAME = "Zoonoses".freeze
    LOCK = "ombudsman_subjects:zoonoses".freeze
    LABELS = YAML.load_file(Rails.root.join("config/zoonoses/domains.yml")).fetch("subtypes")
                 .to_h { |row| [ row.fetch("code"), row.fetch("label") ] }.freeze

    module_function

    def parent_code = Zoonoses::Catalog::SUBJECT_CODE
    def child_code(subtype) = "#{parent_code}.#{subtype}"
    def codes = [ parent_code, *Zoonoses::Catalog::SUBTYPES.map { |subtype| child_code(subtype) } ]

    # O subtipo do assunto reservado (`zoonoses.<subtipo>`), ou nil.
    def subtype_of(subject)
      code = subject&.code
      return nil unless code&.start_with?("#{parent_code}.")

      subtype = code.delete_prefix("#{parent_code}.")
      Zoonoses::Catalog::SUBTYPES.include?(subtype) ? subtype : nil
    end

    # -> { parent: OmbudsmanSubject, children: { subtipo => OmbudsmanSubject } }
    def ensure_zoonoses!(now: Time.current)
      OmbudsmanSubject.ensure_defaults!(now: now)
      found = tree
      return found if found

      OmbudsmanSubject.transaction(requires_new: true) do
        connection = OmbudsmanSubject.connection
        connection.execute("SELECT pg_advisory_xact_lock(hashtext(#{connection.quote(LOCK)}))")
        parent = ensure!(nil, PARENT_NAME, parent_code, now)
        Zoonoses::Catalog::SUBTYPES.each { |subtype| ensure!(parent, LABELS.fetch(subtype), child_code(subtype), now) }
        tree || raise("Ombudsman::Subjects: os assuntos reservados não ficaram completos")
      end
    end

    # A árvore reservada completa e ativa, ou nil.
    def tree
      rows = OmbudsmanSubject.where(code: codes, active: true).index_by(&:code)
      return nil unless rows.size == codes.size

      parent = rows.fetch(parent_code)
      children = Zoonoses::Catalog::SUBTYPES.to_h { |subtype| [ subtype, rows.fetch(child_code(subtype)) ] }
      return nil unless children.values.all? { |child| child.parent_id == parent.id }

      { parent: parent, children: children }
    end

    def ensure!(parent, name, code, now)
      subject = OmbudsmanSubject.find_by(code: code) ||
                OmbudsmanSubject.where(parent_id: parent&.id, code: nil).find_by("lower(name) = lower(?)", name)
      if subject
        changes = { code: code, active: true }.reject { |key, value| subject.public_send(key) == value }
        subject.update!(**changes, updated_at: now) unless changes.empty?
        return subject
      end

      position = OmbudsmanSubject.where(parent_id: parent&.id).maximum(:position).to_i + 1
      OmbudsmanSubject.create!(name: name, parent: parent, code: code, position: position, created_at: now, updated_at: now)
    end

    private_class_method :tree, :ensure!
  end
end
