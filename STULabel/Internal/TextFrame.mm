// Copyright 2017–2018 Stephan Tolksdorf

#import "TextFrame.hpp"

#import "CancellationFlag.hpp"
#import "CoreGraphicsUtils.hpp"
#import "TextFrameLayouter.hpp"

namespace stu_label {

TextFrame::SizeAndOffset TextFrame::objectSizeAndThisOffset(const TextFrameLayouter& layouter) {
  // The data layout must be kept in-sync with
  //   TextFrame::verticalSearchTable
  //   TextFrame::lineStringIndices
  //   STUTextFrameDataGetParagraphs
  //   STUTextFrameDataGetLines
  //   TextFrame::colors()

  static_assert(IntervalSearchTable::arrayElementSize%alignof(STUTextFrameData) == 0
                && sizeof(StringStartIndices)%alignof(STUTextFrameData) == 0
                && alignof(STUTextFrameData) == alignof(STUTextFrameLine)
                && alignof(STUTextFrameData) == alignof(STUTextFrameParagraph)
                && alignof(STUTextFrameData) == alignof(ColorRef)
                && alignof(STUTextFrameData) >= alignof(TextStyle));

  const Int lineCount = layouter.lines().count();

  const UInt verticalSearchTableSize = IntervalSearchTable::sizeInBytesForCount(lineCount);
  const UInt lineStringIndicesTableSize = sizeof(StringStartIndices)*sign_cast(lineCount + 1);
  const Int stylesTerminatorSize = TextStyle::sizeOfTerminatorWithStringIndex(
                                                layouter.rangeInOriginalString().end);
  const ArrayRef<const ColorRef> colors = layouter.colors();

  return {.offset = verticalSearchTableSize + sanitizerGap
                  + lineStringIndicesTableSize + sanitizerGap,
          .size = verticalSearchTableSize
                + sanitizerGap
                + lineStringIndicesTableSize
                + sanitizerGap
                + sizeof(STUTextFrameData)
                + layouter.paragraphs().arraySizeInBytes()
                + layouter.lines().arraySizeInBytes()
                + sanitizerGap
                + colors.arraySizeInBytes()
                + sanitizerGap
                + layouter.originalStringStyles().dataExcludingTerminator().arraySizeInBytes()
                + sign_cast(stylesTerminatorSize)
                + layouter.truncationTokenTextStyleData().arraySizeInBytes()
                + sanitizerGap};
}

TextFrame::TextFrame(TextFrameLayouter&& layouter, UInt dataSize)
: STUTextFrameData{
    .paragraphCount = narrow_cast<Int32>(layouter.paragraphs().count()),
    .lineCount = narrow_cast<Int32>(layouter.lines().count()),
    ._colorCount = narrow_cast<UInt16>(layouter.colors().count()),
    .layoutMode = layouter.layoutMode(),
    .size = layouter.scaleInfo().scale*layouter.inverselyScaledFrameSize(),
    .scaleFactor = layouter.scaleInfo().scale,
    .rangeInOriginalStringIsFullString = layouter.rangeInOriginalStringIsFullString(),
    .rangeInOriginalString = layouter.rangeInOriginalString(),
    .truncatedStringLength = layouter.truncatedStringLength(),
    .originalAttributedString = layouter.attributedString().attributedString,
    ._dataSize = dataSize
  }
{
  incrementRefCount(originalAttributedString);
  const Range<Int32> stringRange = rangeInOriginalString();
  const Int originalStylesTerminatorSize = TextStyle
                                           ::sizeOfTerminatorWithStringIndex(stringRange.end);
  const UInt originalStringTextStyleDataSize = sign_cast(layouter.originalStringStyles()
                                                         .dataExcludingTerminator().count()
                                                         + originalStylesTerminatorSize);
  _textStylesData = reinterpret_cast<const uint8_t*>(this)
                  + dataSize
                  - sanitizerGap
                  - layouter.truncationTokenTextStyleData().count()
                  - originalStringTextStyleDataSize;

#if STU_USE_ADDRESS_SANITIZER
  sanitizer::poison((Byte*)verticalSearchTable().startValues().end(), sanitizerGap);
  sanitizer::poison((Byte*)lineStringIndices().end(), sanitizerGap);
  sanitizer::poison((Byte*)lines().end(), sanitizerGap);
  sanitizer::poison((Byte*)colors().end(), sanitizerGap);
  sanitizer::poison((Byte*)this + _dataSize - sanitizerGap, sanitizerGap);
#endif
  { // Write out the data into the embedded arrays.
    Byte* p = reinterpret_cast<Byte*>(this + 1);
    using array_utils::copyConstructArray;

    layouter.relinquishOwnershipOfCTLinesAndParagraphTruncationTokens();

    copyConstructArray(layouter.paragraphs(), reinterpret_cast<TextFrameParagraph*>(p));
    p += layouter.paragraphs().arraySizeInBytes();

    copyConstructArray(layouter.lines(), reinterpret_cast<TextFrameLine*>(p));
    p += layouter.lines().arraySizeInBytes();
    p += sanitizerGap;

    const ArrayRef<const ColorRef> colors = layouter.colors();
    for (auto& color : colors) {
      CFRetain(color.cgColor());
    }
    copyConstructArray(colors, reinterpret_cast<ColorRef*>(p));
    p += colors.arraySizeInBytes();
    p += sanitizerGap;

    STU_ASSERT(p == _textStylesData);
    const TextStyleSpan originalStyles = layouter.originalStringStyles();
    copyConstructArray(originalStyles.dataExcludingTerminator(), p);
    if (stringRange.start > 0) {
      TextStyle* const style = reinterpret_cast<TextStyle*>(p);
      STU_ASSERT(style->stringIndex() <= stringRange.start);
      style->setStringIndex(stringRange.start);
    }
    p += originalStyles.dataExcludingTerminator().count();
    TextStyle::writeTerminatorWithStringIndex(stringRange.end,
                                              p - originalStyles.lastStyleSizeInBytes(),
                                              ArrayRef{p, originalStylesTerminatorSize});
    p += originalStylesTerminatorSize;
    STU_DEBUG_ASSERT(p + layouter.truncationTokenTextStyleData().count() + sanitizerGap
                     == reinterpret_cast<Byte*>(this) + dataSize);
    copyConstructArray(layouter.truncationTokenTextStyleData(), p);
  }

  const ArrayRef<TextFrameParagraph> paragraphs = const_array_cast(this->paragraphs());
  const ArrayRef<TextFrameLine> lines = const_array_cast(this->lines());
  const ArrayRef<StringStartIndices> lineIndices = const_array_cast(lineStringIndices());

  lineIndices[lines.count()].startIndexInOriginalString = rangeInOriginalString().end;
  lineIndices[lines.count()].startIndexInTruncatedString = truncatedStringLength;

  if (lines.isEmpty()) {
    this->consistentAlignment = STUTextFrameConsistentAlignmentLeft;
    this->flags = STUTextFrameHasMaxTypographicWidth;
    return;
  }

  const CGFloat scale = layouter.scaleInfo().scale;

  bool isTruncated = false;
  TextFlags flags{};
  Rect<CGFloat> layoutBounds = Rect<CGFloat>::infinitelyEmpty();
  const ArrayRef<Float32> increasingMaxYs{const_array_cast(verticalSearchTable().endValues())};
  const ArrayRef<Float32> increasingMinYs{const_array_cast(verticalSearchTable().startValues())};
  Float32 maxY = minValue<Float32>;

  Int32 lineIndex = 0;
  for (TextFrameParagraph& para : paragraphs) {
    isTruncated |= !para.excisedRangeInOriginalString().isEmpty();

    TextFlags paraFlags{};
    for (; lineIndex < para.endLineIndex; ++lineIndex) {
      TextFrameLine& line = lines[lineIndex];

      STU_ASSERT(line._initStep == 5);
      line._initStep = 0;

      paraFlags = paraFlags | TextFlags{line.textFlags()};

      lineIndices[lineIndex].startIndexInOriginalString = line.rangeInOriginalString.start;
      lineIndices[lineIndex].startIndexInTruncatedString = line.rangeInTruncatedString.start;
      const CGFloat x = narrow_cast<CGFloat>(line.originX);
      const CGFloat y = narrow_cast<CGFloat>(line.originY);
      
      layoutBounds.x = layoutBounds.x.convexHull(Range{x, x + line.width});
      if (line.hasTruncationToken) {
        line._tokenStylesOffset += originalStringTextStyleDataSize;
      }
      if (line.textFlags() & (TextFlags::decorationFlags | TextFlags::hasAttachment)) {
        stu_label::detail::adjustFastTextFrameLineBoundsToAccountForDecorationsAndAttachments(
                             line, layouter.localFontInfoCache());
      }

      // We want to use the vertical search table for finding lines whose typographic or image
      // bounds intersect vertically with a specified range, so we we construct the table from the
      // union of the line's typographic bounds and its fast image bounds.
      const auto halfLeading = line.leading/2;
      maxY = max(maxY, narrow_cast<Float32>(y + max(-line.fastBoundsLLOMinY,
                                                    line.descent + halfLeading)));
      increasingMaxYs[lineIndex] = maxY;
      // We'll do a second pass over the increasingMinYs below.
      increasingMinYs[lineIndex] = narrow_cast<Float32>(y - max(line.fastBoundsLLOMaxY,
                                                                line.ascent + halfLeading));
    }
    implicit_cast<STUTextFrameParagraph&>(para).textFlags = static_cast<STUTextFlags>(paraFlags);
    flags |= paraFlags;
  }

  layoutBounds.y = Range{narrow_cast<CGFloat>(lines[0].originY - lines[0].heightAboveBaseline),
                         narrow_cast<CGFloat>(lines[$ - 1].originY
                                              + lines[$ - 1].heightBelowBaseline)};

  this->layoutBounds = scale*layoutBounds;

  {
    Float32 minY = infinity<Float32>;
    STU_DISABLE_LOOP_UNROLL
    for (Float32& value : increasingMinYs.reversed()) {
      value = minY = min(value, minY);
    }
  }

  STUTextFrameConsistentAlignment consistentAlignment = stuTextFrameConsistentAlignment(
                                                          paragraphs[0].alignment);
  for (const TextFrameParagraph& para : paragraphs[{1, $}]) {
    if (consistentAlignment != stuTextFrameConsistentAlignment(para.alignment)) {
      consistentAlignment = STUTextFrameConsistentAlignmentNone;
      break;
    }
  }

  const bool isScaled = this->scaleFactor < 1;

  bool hasMaxTypographicWidth = consistentAlignment != STUTextFrameConsistentAlignmentNone
                             && !isTruncated
                             && !isScaled;
  if (hasMaxTypographicWidth) {
    Int32 i = 0;
    for (const TextFrameParagraph& para : paragraphs) {
      if (para.endLineIndex == ++i) continue;
      hasMaxTypographicWidth = false;
      break;
    }
  }

  this->consistentAlignment = consistentAlignment;
  this->flags = static_cast<STUTextFrameFlags>(
                  static_cast<STUTextFrameFlags>(flags)
                  | (isTruncated ? STUTextFrameIsTruncated : 0)
                  | (isScaled ? STUTextFrameIsScaled : 0)
                  | (hasMaxTypographicWidth ? STUTextFrameHasMaxTypographicWidth : 0));
}


TextFrame::~TextFrame() {
  if (const void* const bs = atomic_load_explicit(&_backgroundSegments, memory_order_relaxed)) {
    free(const_cast<void*>(bs));
  }
  if (flags & STUTextFrameIsTruncated) {
    if (const CFAttributedString* const ts = atomic_load_explicit(&_truncatedAttributedString,
                                                                  memory_order_relaxed))
    {
      discard((__bridge_transfer NSAttributedString*)ts); // Releases the string.
    }
    for (const TextFrameParagraph& para : paragraphs().reversed()) {
      if (para.truncationToken) {
        decrementRefCount(para.truncationToken);
      }
    }
  }
  for (const TextFrameLine& line : lines().reversed()) {
    line.releaseCTLines();
  }
  for (ColorRef color : colors()) {
    decrementRefCount(color.cgColor());
  }
  decrementRefCount(originalAttributedString);

#if STU_USE_ADDRESS_SANITIZER
  sanitizer::unpoison((Byte*)verticalSearchTable().startValues().end(), sanitizerGap);
  sanitizer::unpoison((Byte*)lineStringIndices().end(), sanitizerGap);
  sanitizer::unpoison((Byte*)lines().end(), sanitizerGap);
  sanitizer::unpoison((Byte*)colors().end(), sanitizerGap);
  sanitizer::unpoison((Byte*)this + _dataSize - sanitizerGap, sanitizerGap);
#endif
}

Rect<CGFloat> TextFrame::calculateImageBounds(TextFrameOrigin originalTextFrameOrigin,
                                              const ImageBoundsContext& originalContext) const
{
  ImageBoundsContext context{originalContext};
  Point<Float64> textFrameOrigin{originalTextFrameOrigin};
  if (scaleFactor < 1) {
    textFrameOrigin /= scaleFactor;
    if (context.displayScale) {
      context.displayScale = DisplayScale::create(scaleFactor**context.displayScale);
    }
  }
  Rect<Float64> bounds = Rect<Float64>::infinitelyEmpty();
  ArrayRef<const TextFrameLine> lines = this->lines();
  if (context.styleOverride) {
    lines = lines[context.styleOverride->drawnLineRange];
  }
  for (const TextFrameLine& line : lines) {
    Rect<CGFloat> r = line.calculateImageBoundsLLO(context);
    if (context.isCancelled()) break;
    if (r.isEmpty()) continue;
    r.y *= -1;
    Point<Float64> lineOrigin = textFrameOrigin + line.origin();
    if (context.displayScale) {
      lineOrigin.y = ceilToScale(lineOrigin.y, *context.displayScale);
    }
    bounds = bounds.convexHull(lineOrigin + r);
  }
  if (bounds.x.start == Rect<Float64>::infinitelyEmpty().x.start) {
    return Rect<CGFloat>{narrow_cast<CGPoint>(originalTextFrameOrigin.value), {}};
  }
  return narrow_cast<Rect<CGFloat>>(scaleFactor*bounds);
}


} // namespace stu_label
