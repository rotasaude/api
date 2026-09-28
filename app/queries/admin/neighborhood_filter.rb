# Filtro de bairro dos cinco painéis com cidadão (ADR 0023; spec 2026-09-28
# §4.3). Objeto único: recorta as relações e suprime os números. Desligado
# (parâmetro ausente — o console admin nunca o manda), devolve tudo intacto.
#
#   neighborhood_id=<uuid> → um bairro (ativo ou inativo: o filtro vale para o histórico)
#   neighborhood_id=none   → sem bairro (inclui conversa sem cidadão)
#
# Triagem e relatório: bairro COPIADO na triagem. Conversa: bairro ATUAL do
# cidadão (a conversa não tem cópia).
class Admin::NeighborhoodFilter
  class Invalid < StandardError; end

  NONE = "none"
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  def self.off
    new(mode: :off)
  end

  def self.parse(raw)
    return off if raw.nil? || raw == ""
    raise Invalid unless raw.is_a?(String)
    return new(mode: :none) if raw == NONE
    raise Invalid unless raw.match?(UUID)

    neighborhood = Neighborhood.find_by(id: raw) || raise(Invalid)
    new(mode: :one, neighborhood: neighborhood)
  end

  def initialize(mode:, neighborhood: nil)
    @mode = mode
    @neighborhood = neighborhood
  end

  def active?
    @mode != :off
  end

  def descriptor
    case @mode
    when :off then nil
    when :none then NONE
    else { id: @neighborhood.id, name: @neighborhood.name }
    end
  end

  def triages(relation)
    active? ? relation.where(triages: { neighborhood_id: value }) : relation
  end

  def conversations(relation)
    active? ? relation.left_joins(:citizen).where(citizens: { neighborhood_id: value }) : relation
  end

  def report_snapshots(relation)
    active? ? relation.joins(:triage).where(triages: { neighborhood_id: value }) : relation
  end

  def count(n)
    return n unless active?
    raise ArgumentError, "count expects a Numeric or nil, got #{n.class}" unless n.nil? || n.is_a?(Numeric)

    Admin::SmallCount.wrap(n)
  end

  def series(values)
    return values unless active?
    raise ArgumentError, "series expects an Array, got #{values.class}" unless values.is_a?(Array)

    values.map { |v| Admin::SmallCount.wrap(v) }
  end

  # Taxa ou média calculada sobre `total`.
  def over(total, value)
    active? && Admin::SmallCount.small?(total) ? Admin::SmallCount::SUPPRESSED : value
  end

  # Fatia de uma categoria: some se a categoria ou o total for pequeno (com
  # os dois à mostra, a fatia devolveria a contagem suprimida).
  def share(count, total, value)
    return value unless active?
    return Admin::SmallCount::SUPPRESSED if Admin::SmallCount.small?(count) || Admin::SmallCount.small?(total)

    value
  end

  # Lista de amostra: null quando o total filtrado é pequeno (a chave fica).
  def list(total, rows)
    active? && Admin::SmallCount.small?(total) ? nil : rows
  end

  private

  def value
    @mode == :none ? nil : @neighborhood.id
  end
end
