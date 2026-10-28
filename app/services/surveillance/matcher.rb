# Correspondência de um código de problema com a lista (Desvio 1; K2): CID-10
# de 4 caracteres casa exato, de 3 cobre a categoria; CIAP-2 exato; as
# terminologias não se misturam. K12(d): se o código casa na plataforma e numa
# doença local, vence a da plataforma, sempre.
module Surveillance
  module Matcher
    module_function

    def disease_for(terminology, code, diseases)
      field = { "cid10" => :cid10, "ciap2" => :ciap2 }[terminology.to_s]
      value = code.to_s
      return nil if field.nil? || value.empty?

      hits = diseases.select { |d| d.public_send(field).any? { |entry| covers?(terminology.to_s, entry, value) } }
      hits.find { |d| !d.local } || hits.first
    end

    def covers?(terminology, entry, code)
      return entry == code unless terminology == "cid10"

      entry == code || (entry.length == 3 && code.length == 4 && code.start_with?(entry))
    end
    private_class_method :covers?
  end
end
