require "securerandom"
require "time"

# Mensagens de exemplo do middleware simulado (ADR 0037; contrato §12):
# valores fixos por código de aparelho da semente, com um crítico (GLI 450)
# e uma repetição (GLI 98). Nunca dado do paciente.
module FakeMiddleware
  module Messages
    VALUES = {
      "GLI" => [ [ [ "glicose", "450", "mg/dL" ] ], [ [ "glicose", "98", "mg/dL" ] ] ],
      "A1C" => [ [ [ "hba1c", "6.8", "%" ] ] ],
      "COL" => [ [ [ "colesterol_total", "212", "mg/dL" ] ] ],
      "HDL" => [ [ [ "hdl", "44", "mg/dL" ] ] ],
      "LDL" => [ [ [ "ldl", "138", "mg/dL" ] ] ],
      "TRI" => [ [ [ "triglicerideos", "164", "mg/dL" ] ] ],
      "CRE" => [ [ [ "creatinina", "0.92", "mg/dL" ] ] ],
      "URE" => [ [ [ "ureia", "31", "mg/dL" ] ] ],
      "TGO" => [ [ [ "tgo", "22", "U/L" ] ] ],
      "TGP" => [ [ [ "tgp", "25", "U/L" ] ] ],
      "TSH" => [ [ [ "tsh", "2.15", "m[IU]/L" ] ] ],
      "T4L" => [ [ [ "t4_livre", "1.21", "ng/dL" ] ] ],
      "HCG" => [ [ [ "beta_hcg", "1.2", "m[IU]/mL" ] ] ],
      "HEM" => [ [ [ "hemacias", "4.61", "10*6/uL" ], [ "hemoglobina", "13.4", "g/dL" ], [ "hematocrito", "40.2", "%" ],
                   [ "vcm", "87.2", "fL" ], [ "hcm", "29.1", "pg" ], [ "chcm", "33.3", "g/dL" ], [ "rdw", "12.9", "%" ],
                   [ "leucocitos", "7.2", "10*3/uL" ], [ "plaquetas", "250", "10*3/uL" ] ] ]
    }.freeze

    module_function

    def header(type, control) = "MSH|^~\\&|MW-SIMULADO|LAB-MUNICIPAL|ROTA-SAUDE|CIDADE|#{Time.now.utc.strftime('%Y%m%d%H%M%S')}||#{type}|#{control}|P|2.5.1"

    def control_id = "M#{SecureRandom.hex(8)}"

    def qbp(barcode)
      [ header("QBP^Q11^QBP_Q11", "Q#{SecureRandom.hex(6)}"), "QPD|LabWorklist^Lista de trabalho^99RSL|T#{SecureRandom.hex(3)}|#{barcode}", "RCP|I" ].join("\r") + "\r"
    end

    # spm4: SPM-4 copiado do RSP^K11 (material_key^rótulo^99RSL), como faz um middleware real.
    def oul(barcode, code, values, control: control_id, spm4: nil)
      obx = values.each_with_index.map { |(key, value, unit), i| "OBX|#{i + 1}|NM|#{key}^#{key}^99RSL||#{value}|#{unit}^^UCUM|||||F" }
      spm = [ "SPM", "1", barcode, "", spm4.to_s ].join("|").sub(/\|+\z/, "")
      ([ header("OUL^R22^OUL_R22", control), spm, "OBR|1|||#{code}^#{code}^99RSL" ] + obx).join("\r") + "\r"
    end

    # OBR-4.1 de cada exame do RSP^K11.
    def codes(rsp) = rsp.to_s.split("\r").select { |s| s.start_with?("OBR|") }.map { |s| s.split("|")[4].to_s.split("^").first }

    # SPM-4 (CWE completo) do RSP^K11, ou nil.
    def spm4(rsp) = rsp.to_s.split("\r").find { |s| s.start_with?("SPM|") }&.split("|")&.at(4)

    def msa(reply) = reply.to_s.split("\r").find { |s| s.start_with?("MSA|") }&.split("|")&.at(1)
  end
end
