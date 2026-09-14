# Conteúdo inicial de uma cidade nova (Plano 4): o protocolo template que o
# provisionamento semeia como rascunho, e que os seeds de dev ativam.
module CityTemplates
  PROTOCOL_PATH = "config/city_templates/triage_respiratoria.json"

  module_function

  # { name:, definition: } — o formato de SeedProtocol.call(template:).
  def protocol
    definition = JSON.parse(Rails.root.join(PROTOCOL_PATH).read)
    { name: definition.fetch("name"), definition: definition }
  end
end
