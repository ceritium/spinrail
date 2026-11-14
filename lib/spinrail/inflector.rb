module Spinrail
  # Regular English only; enough for conventional table and resource names.
  module Inflector
    module_function

    def underscore(word)
      word.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    def camelize(word)
      word.split(/[_\/]/).map(&:capitalize).join
    end

    def humanize(word)
      word.sub(/_id\z/, "").tr("_", " ").capitalize
    end

    def pluralize(word)
      return word.sub(/y\z/, "ies") if word.match?(/[^aeiou]y\z/)
      return word + "es" if word.match?(/(s|x|z|ch|sh)\z/)
      word + "s"
    end

    def singularize(word)
      return word.sub(/ies\z/, "y") if word.end_with?("ies")
      return word.sub(/es\z/, "") if word.match?(/(s|x|z|ch|sh)es\z/)
      word.sub(/s\z/, "")
    end

    def tableize(class_name)
      pluralize(underscore(class_name))
    end
  end
end
