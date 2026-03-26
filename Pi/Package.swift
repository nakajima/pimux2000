// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
	name: "Pi",
	platforms: [
		.iOS(.v17),
		.macOS(.v15),
	],
	products: [
		// Products define the executables and libraries a package produces, making them visible to other packages.
		.library(
			name: "Pi",
			targets: ["Pi"]
		),
		.executable(
			name: "pi-client",
			targets: ["PiClientCLI"]
		),
	],
	dependencies: [
		.package(path: "Packages/PiIOSSystemSupport"),
		.package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.7.0"),
	],
	targets: [
		// Targets are the basic building blocks of a package, defining a module or a test suite.
		// Targets can depend on other targets in this package and products from dependencies.
		.target(
			name: "Pi",
			dependencies: [
				.product(name: "PiIOSSystemSupport", package: "PiIOSSystemSupport", condition: .when(platforms: [.iOS])),
				.product(name: "Citadel", package: "Citadel"),
			]
		),
		.executableTarget(
			name: "PiClientCLI",
			dependencies: ["Pi"]
		),
		.testTarget(
			name: "PiTests",
			dependencies: ["Pi"]
		),
	]
)
