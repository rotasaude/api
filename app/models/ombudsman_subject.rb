# Assunto da manifestação (ADR 0051; contrato §7): dois níveis (assunto e
# subassunto; trigger), nome único por pai sem distinguir caixa. A migração
# insere a semente; o banco carregado do dump nasce sem ela (ensure_defaults!).
# Nunca é apagado (trigger): desativa-se.
class OmbudsmanSubject < ApplicationRecord
  # Contrato §7: assuntos e subassuntos iniciais (a cidade edita).
  DEFAULT_TREE = [
    [ "Atendimento", [ "Demora", "Conduta de profissional", "Acolhimento" ] ],
    [ "Acesso", [ "Agendamento", "Fila", "Falta de profissional" ] ],
    [ "Medicamentos", [ "Falta", "Dispensação" ] ],
    [ "Exames", [ "Agendamento", "Resultado" ] ],
    [ "Estrutura", [ "Limpeza", "Instalações" ] ],
    [ "Transporte", [] ],
    [ "Vigilância em saúde", [] ],
    [ "Outros", [] ]
  ].freeze

  belongs_to :parent, class_name: "OmbudsmanSubject", optional: true
  has_many :children, -> { order(:position, :name) }, class_name: "OmbudsmanSubject", foreign_key: :parent_id,
                                                       inverse_of: :parent, dependent: :restrict_with_error

  validates :name, length: Ombudsman::Catalog::NAME

  scope :active, -> { where(active: true) }

  # A semente só entra com a tabela vazia, nunca item a item (Q47): assunto
  # renomeado ou desativado pela cidade não reaparece. Concorrente: o índice
  # único descarta a repetição e os filhos apontam os pais gravados.
  def self.ensure_defaults!(now: Time.current)
    return true if exists?

    transaction do
      parents = DEFAULT_TREE.each_with_index.map do |(name, _), index|
        { "name" => name, "position" => index + 1, "created_at" => now, "updated_at" => now }
      end
      insert_all(parents)
      ids = where(parent_id: nil, name: DEFAULT_TREE.map(&:first)).pluck(:name, :id).to_h
      children = DEFAULT_TREE.flat_map do |name, names|
        names.each_with_index.map do |child, index|
          { "name" => child, "parent_id" => ids.fetch(name), "position" => index + 1, "created_at" => now, "updated_at" => now }
        end
      end
      insert_all(children)
    end
    true
  end
end
