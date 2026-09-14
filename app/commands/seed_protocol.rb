# Copia um template de protocolo para dentro da cidade da conexão corrente como
# rascunho (ADR-0013). Author/publisher da cidade revisa e publica depois.
class SeedProtocol
  def self.call(template:)
    raise ArgumentError, "template requerido" if template.nil?
    ProtocolDefinition.create!(
      name: template.fetch(:name),
      definition: template.fetch(:definition),
      version: 1,
      status: "draft"
    )
  end
end
