# Copia um template de protocolo para dentro de uma cidade como rascunho
# (ADR-0024). Author/publisher da cidade revisa e publica depois.
class SeedProtocol
  def self.call(municipality:, template:)
    raise ArgumentError, "template requerido" if template.nil?
    ProtocolDefinition.create!(
      municipality_id: municipality.id,
      name: template.fetch(:name),
      definition: template.fetch(:definition),
      version: 1,
      status: "draft"
    )
  end
end
