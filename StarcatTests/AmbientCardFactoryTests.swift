//
//  AmbientCardFactoryTests.swift
//  StarcatTests
//
//  校验 Repo minimal 映射、Owner 大小写聚合与头像回退。
//

import Testing
@testable import Starcat

@Suite("Ambient Card Factory")
struct AmbientCardFactoryTests {
    @Test("Repo minimal 卡片只保留稳定展示字段")
    func buildsMinimalRepoCard() throws {
        var repo = Repo.makeMinimal(owner: "OpenAI", name: "codex")
        repo.id = 42
        repo.ownerAvatar = " https://avatars.githubusercontent.com/u/1?v=4 "

        let cards = AmbientCardFactory.cards(from: [repo], scene: .repos)
        let card = try #require(cards.first)

        #expect(card.id == "repo:42")
        #expect(card.visualKey == "owner:openai")
        #expect(card.title == "OpenAI/codex")
        #expect(card.artworkURLString == "https://avatars.githubusercontent.com/u/1?v=4")
        #expect(card.subtitle == nil)
        #expect(card.metadata.isEmpty)
    }

    @Test("Owner 按大小写不敏感聚合并保留首次展示名")
    func groupsOwnersCaseInsensitively() throws {
        var first = Repo.makeMinimal(owner: "OpenAI", name: "codex")
        first.id = 1
        var second = Repo.makeMinimal(owner: "openai", name: "openai-python")
        second.id = 2
        second.ownerAvatar = "https://avatars.githubusercontent.com/u/14957082"

        let cards = AmbientCardFactory.cards(from: [first, second], scene: .owners)
        let owner = try #require(cards.first)

        #expect(cards.count == 1)
        #expect(owner.id == "owner:openai")
        #expect(owner.visualKey == "owner:openai")
        #expect(owner.title == "OpenAI")
        #expect(owner.artworkURLString == "https://avatars.githubusercontent.com/u/14957082")
    }

    @Test("缺少 avatar 时回退 GitHub owner 端点")
    func fallsBackToOwnerAvatarURL() throws {
        var repo = Repo.makeMinimal(owner: "apple", name: "swift")
        repo.id = 3

        let card = try #require(AmbientCardFactory.cards(from: [repo], scene: .repos).first)

        #expect(card.artworkURLString == RepoAvatarURL.from(owner: "apple"))
    }
}
