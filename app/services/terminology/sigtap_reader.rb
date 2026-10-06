# app/services/terminology/sigtap_reader.rb
module Terminology
  class SigtapReader
    def initialize(archive)
      @archive = archive
    end

    def write(_release) = raise(Import::Invalid, "leitor da SIGTAP ainda não implementado")
  end
end
