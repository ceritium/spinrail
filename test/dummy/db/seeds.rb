author = Author.create(name: "Seeded", email: "seed@example.com")
Post.create(author_id: author.id, title: "Seeded post", body: "from seeds", rating: 1.0)
