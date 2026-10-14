require "json"
require "base64"
require "time"
require "prawn"

Prawn::Fonts::AFM.hide_m17n_warning = true # fontes embutidas: só o texto fixo em pt-BR (WinAnsi)

# Laudo de exemplo do laboratório simulado (ADR 0036; contrato §13): só o
# perfil de entrada, valores fixos de demonstração, PDF "sem validade" sem
# nenhum dado do paciente (o CPF vem e volta só no subject).
module FakeLab
  module Report
    ANALYTES = {
      "0202020380" => [ [ "hb", "718-7", "Hemoglobin [Mass/volume] in Blood", 13.4, "g/dL" ],
                        [ "leuco", "6690-2", "Leukocytes [#/volume] in Blood", 7.2, "10*3/uL" ],
                        [ "plaq", "777-3", "Platelets [#/volume] in Blood", 250, "10*3/uL" ] ],
      "0202010503" => [ [ "hba1c", "4548-4", "Hemoglobin A1c/Hemoglobin.total in Blood", 6.8, "%" ] ]
    }.freeze

    module_function

    def build(service_request, now: Time.now)
      short_code = service_request.dig("identifier", 0, "value")
      sigtap = service_request.dig("code", "coding", 0, "code")
      observations = observations(sigtap)
      { "resourceType" => "DiagnosticReport", "identifier" => [ { "system" => "urn:fake-lab", "value" => "FAKE-#{short_code}" } ],
        "status" => "final", "code" => { "coding" => [ { "system" => "http://www.saude.gov.br/fhir/r4/CodeSystem/BRTabelaSUS", "code" => sigtap } ] },
        "basedOn" => [ { "identifier" => { "value" => short_code } } ], "subject" => service_request["subject"],
        "issued" => now.utc.iso8601, "performer" => [ { "display" => "Laboratório Simulado" } ],
        "presentedForm" => [ { "contentType" => "application/pdf", "data" => Base64.strict_encode64(pdf(short_code, sigtap)) } ],
        "result" => observations.map { |o| { "reference" => "##{o['id']}" } }, "contained" => observations }
    end

    def observations(sigtap)
      rows = ANALYTES[sigtap]
      return [ { "resourceType" => "Observation", "id" => "texto", "status" => "final",
                 "code" => { "coding" => [ { "system" => "http://loinc.org", "code" => "22637-3", "display" => "Pathology report final diagnosis" } ] },
                 "valueString" => "Resultado simulado — sem validade" } ] unless rows

      rows.map do |id, loinc, display, value, unit|
        { "resourceType" => "Observation", "id" => id, "status" => "final",
          "code" => { "coding" => [ { "system" => "http://loinc.org", "code" => loinc, "display" => display } ] },
          "valueQuantity" => { "value" => value, "unit" => unit } }
      end
    end

    def pdf(short_code, sigtap)
      Prawn::Document.new do |doc|
        doc.text "LABORATÓRIO SIMULADO — sem validade", size: 16
        doc.text "Guia #{short_code} · SIGTAP #{sigtap}"
        doc.text "Documento de desenvolvimento do Rota Saúde."
      end.render
    end
    private_class_method :observations, :pdf
  end
end
